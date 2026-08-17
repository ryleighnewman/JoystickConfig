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
        connectingControllers,
        builtInExamples,
        presetGroups,
        dualSenseEdge,
        midiInput,
        switchProController,
        joyConSetup,
        stadiaController,
        accessControllerProfile,
        eightBitDoMode,
        genericHIDController,
        variableSensitivity,
        midiOutput,
        hapticFeedback,
        speechFeedback,
        lightBar,
        touchpadAsMouse,
        steamController,
        gyroscopeAim,
        oneStickDriving,
        dataPersistence,
    ]

    // MARK: - Guides

    static let midiInput = HelpGuide(
        id: "midi-input",
        title: "MIDI Devices as Input",
        category: "Controller setup",
        summary: "Use a MIDI keyboard, pad controller, or knob box to drive your Mac: bind notes, pads, knobs, the pitch wheel, and the sustain pedal to keys, clicks, macros, or anything else.",
        sections: [
            HelpSection(
                heading: "Getting started",
                body: "Connect your MIDI device over USB or Bluetooth MIDI. InputConfig finds it automatically, with no setup and no drivers. Then open a preset, add a binding, set its input type to MIDI, and press Scan: play a key, twist a knob, or move the pitch wheel and it is captured."
            ),
            HelpSection(
                heading: "What you can bind",
                steps: [
                    "Notes and pads behave like buttons: the binding is held while the key is down.",
                    "Control Change knobs, sliders, and pedals fire once they pass the halfway point, so a sustain pedal works as an on/off switch.",
                    "The pitch wheel is centre-resting, so bind it in the plus or minus direction like a joystick axis.",
                    "Aftertouch fires when you press harder into a held key.",
                    "Program Change fires once each time the patch changes.",
                ]
            ),
            HelpSection(
                heading: "Channels and devices",
                body: "Every binding defaults to any channel and any device, which is what most people want: your preset keeps working when you plug in a different keyboard. Pick a specific channel when a device sends on several at once, for example splitting a keyboard so the lower octaves control your Mac and the rest still plays your music software."
            ),
            HelpSection(
                heading: "Sending MIDI as well",
                body: "This is the reverse of the MIDI outputs InputConfig already sends. You can use both at once: map a controller button to a MIDI note going out to your music app, and a knob on your MIDI keyboard to a keyboard shortcut coming in. InputConfig never listens to its own output port, so the two cannot loop back into each other."
            ),
        ]
    )

    static let dualSenseEdge = HelpGuide(
        id: "dualsense-edge",
        title: "DualSense Edge Extra Buttons",
        category: "Controller setup",
        summary: "The Edge's back paddles, FN buttons, and mute button are bindable like any other input, over Bluetooth or USB-C.",
        sections: [
            HelpSection(
                heading: "How it works",
                body: "Apple's controller framework does not report the Edge's extra buttons, so InputConfig reads them straight from the controller's data stream alongside the normal inputs. This works on both Bluetooth and USB."
            ),
            HelpSection(
                heading: "Binding them",
                steps: [
                    "Open a preset, add a binding, and press Scan, then press a paddle or FN button.",
                    "Or watch the Live Visualizer: the extra buttons appear as chips that light up when pressed.",
                    "Left Paddle is button 16, Right Paddle 17, FN left 20, FN right 21, Mute 15."
                ]
            ),
            HelpSection(
                heading: "If the extra buttons stop responding",
                body: "A long-lived Bluetooth session can occasionally wedge into a state where the extra buttons go quiet even though sticks and face buttons still work. Power the controller off and on (hold the PS button to turn it off) and they come back. Remember the paddles are detachable: an empty rear socket reports nothing."
            ),
            HelpSection(
                heading: "Paddle assignments on the controller",
                body: "If you assigned the paddles to mirror other buttons using Sony's own profile tool on a PS5, the controller sends both the mirrored button and the paddle bit. Unassigned paddles still report presses to InputConfig, so you can bind them even when they do nothing in other software."
            ),
        ]
    )

    static let oneStickDriving = HelpGuide(
        id: "one-stick-driving",
        title: "One-Stick Driving",
        category: "Driving and vehicles",
        summary: "Drive a vehicle with a single joystick: steer, accelerate, brake, and shift between Drive and Reverse, all from one stick. Built for racing and driving games you can control with the keyboard and mouse.",
        sections: [
            HelpSection(heading: "What it does",
                        body: "One-stick driving turns a single analog stick into a whole vehicle control scheme, the way a power wheelchair drives. Left and right steers; pushing forward accelerates and pulling back brakes. Because the app sends keyboard and mouse, variable throttle works by pulsing the accelerate key quickly, so pushing the stick further holds the key a larger share of each cycle, which most games read as proportional speed. Steering is smooth mouse movement by default."),
            HelpSection(heading: "Turning it on",
                        body: "Open a preset and scroll to the One-Stick Driving panel just below the joystick groups, then switch it on. The fastest start is the built-in One-Stick Racing preset in the Smart Preset Maker.",
                        steps: [
                            "Pick which stick drives: Left, Right, or Custom axes.",
                            "Move the stick and watch the live readout to confirm the right axes respond.",
                            "Set the accelerate and brake keys to match your game (W and S by default).",
                            "Choose mouse or A and D keys for steering."]),
            HelpSection(heading: "Shifting into Reverse",
                        body: "Snap the stick fully back to the wall a couple of times quickly to shift into Reverse. While in Reverse, pushing forward drives backward; push the stick fully forward to return to Drive. The tap count, timing window, and wall threshold are all adjustable in the editor."),
            HelpSection(heading: "Tips",
                        steps: [
                            "If the vehicle launches the instant you enable drive, your throttle axis is probably an analog trigger that rests at one end. Turn on the trigger option in the Throttle section.",
                            "Raise the sensitivity curve for finer low-speed control.",
                            "This works in any game you can drive with the keyboard and mouse. Games that only accept a gamepad are not supported, because the app does not emulate a controller."]),
        ])

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
                    "After each switch, try pressing a button in InputConfig's input scanner to see if it now registers.",
                    "If none of the three profiles produce input, plug the controller into a PlayStation 5, open the Access Controller settings, and confirm that at least one profile has buttons assigned. You can also restore the default profile from that menu.",
                    "Once the profile is configured, unplug the controller from the PS5 and reconnect it to your Mac. InputConfig should now receive input."
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
                body: "Plug the controller into your Mac with a USB-C cable. Most modern controllers, including the DualSense, DualSense Edge, and Xbox controllers, work this way without any setup. If InputConfig does not detect it, click Refresh Controllers in the controller chip popover."
            ),
            HelpSection(
                heading: "Bluetooth",
                steps: [
                    "Put the controller into pairing mode. On a DualSense, hold the PS and Create buttons together until the light bar starts flashing.",
                    "On your Mac, open System Settings > Bluetooth.",
                    "Wait for the controller to appear in the list of nearby devices and click Connect.",
                    "Once paired, InputConfig should detect it within a few seconds."
                ]
            ),
            HelpSection(
                heading: "If the controller does not appear",
                body: "Disconnect from any other paired device first. Controllers can only be paired with one device at a time, so if it is still paired to a PlayStation or Xbox, unpair it there first."
            ),
        ]
    )

    static let switchProController = HelpGuide(
        id: "switch-pro-controller",
        title: "Nintendo Switch Pro Controller",
        category: "Controllers",
        summary: "macOS Ventura (13.0) and later support the Nintendo Switch Pro Controller natively. It pairs over Bluetooth and shows up in InputConfig as a standard extended gamepad.",
        sections: [
            HelpSection(
                heading: "Pairing",
                steps: [
                    "Press and hold the small Sync button on the top of the Pro Controller (next to the USB-C port) until the four player LEDs run back and forth.",
                    "On your Mac, open System Settings then Bluetooth.",
                    "Wait for Pro Controller to appear in Nearby Devices and click Connect.",
                    "The controller will then move to My Devices and InputConfig will detect it within a few seconds."
                ]
            ),
            HelpSection(
                heading: "Button layout",
                body: "The Switch labels the bottom face button B and the right face button A, the opposite of Xbox and PlayStation. InputConfig uses logical indices (0 through 12), so a binding for index 0 fires on whatever button the Switch calls B. If you imported a preset built for an Xbox controller, you may want to swap A and B by re-scanning those bindings."
            ),
            HelpSection(
                heading: "Limitations",
                body: "Motion controls and HD rumble are not exposed through the GameController framework on macOS, so InputConfig cannot use the gyroscope or fine haptics on the Pro Controller. Standard rumble and all face and shoulder buttons work fine."
            ),
            HelpSection(
                heading: "If it does not pair",
                body: "Unpair the controller from your Switch first, since Nintendo Switch hardware only pairs with one device at a time. On the Switch, go to System Settings, Controllers and Sensors, Disconnect Controllers, and hold L plus R when prompted."
            ),
        ]
    )

    static let joyConSetup = HelpGuide(
        id: "joy-con-setup",
        title: "Nintendo Joy-Cons",
        category: "Controllers",
        summary: "Joy-Cons connect to macOS as separate controllers, one per Joy-Con. macOS 13 and later supports combining them as a pair, but each Joy-Con also works on its own.",
        sections: [
            HelpSection(
                heading: "Pairing each Joy-Con",
                steps: [
                    "Detach the Joy-Cons from the Switch console.",
                    "Hold the small Sync button on the side of each Joy-Con (the side that normally faces the rail) until the LEDs run back and forth.",
                    "Open System Settings then Bluetooth on your Mac.",
                    "Wait for Joy-Con (L) and Joy-Con (R) to appear in Nearby Devices, and click Connect on each one.",
                    "Both Joy-Cons will then appear separately in InputConfig's controller list."
                ]
            ),
            HelpSection(
                heading: "Using one Joy-Con alone",
                body: "A single Joy-Con held sideways has four face buttons and two shoulder buttons. InputConfig sees these as a small extended gamepad. The directional buttons on the left Joy-Con appear as the four face buttons, while the right Joy-Con keeps its A, B, X, Y labels."
            ),
            HelpSection(
                heading: "Using both as a pair",
                body: "On macOS 13 and later, when both Joy-Cons are connected they may also appear as a single combined controller. This shows up as Joy-Con Pair and behaves like a normal full-size gamepad. Bindings made on the pair will not transfer to a single Joy-Con and vice versa, so pick one mode and stick with it for each preset."
            ),
            HelpSection(
                heading: "Limitations",
                body: "IR camera, NFC, accelerometer, and gyroscope on the Joy-Cons are not exposed through the GameController framework. InputConfig can read buttons and the small analog sticks, which is enough for most desktop and game uses."
            ),
        ]
    )

    static let stadiaController = HelpGuide(
        id: "stadia-controller",
        title: "Google Stadia Controller",
        category: "Controllers",
        summary: "Google's Stadia controller works on macOS over Bluetooth. The controller has to be unlocked using Google's Bluetooth update tool before it can pair with anything other than Stadia itself.",
        sections: [
            HelpSection(
                heading: "Unlock the controller first",
                steps: [
                    "Go to stadia.google.com/controller on a computer.",
                    "Follow Google's instructions to put the controller into pairing mode and update it. This unlocks Bluetooth pairing permanently.",
                    "After the update, the controller no longer requires Stadia and can pair with any Bluetooth host."
                ]
            ),
            HelpSection(
                heading: "Pairing with macOS",
                steps: [
                    "Hold the Stadia, Y, and A buttons together for two seconds, then release. The status light starts pulsing.",
                    "On your Mac, open System Settings then Bluetooth.",
                    "Click Connect on Stadia Controller in Nearby Devices.",
                    "InputConfig will detect it as a standard extended gamepad."
                ]
            ),
            HelpSection(
                heading: "Button layout",
                body: "Stadia follows the Xbox layout: A on the bottom, B on the right, X on the left, Y on top. Any preset built for an Xbox controller will work without changes."
            ),
        ]
    )

    static let genericHIDController = HelpGuide(
        id: "generic-hid-controller",
        title: "Other Controllers",
        category: "Controllers",
        summary: "InputConfig uses Apple's GameController framework to read input. That framework supports most current and recent controllers, but a few older or unofficial controllers may not show up.",
        sections: [
            HelpSection(
                heading: "What works without setup",
                body: "Any controller that is recognized by macOS as MFi-compatible will work. This includes PlayStation 4 and 5 controllers, Xbox One and Series controllers, Switch Pro and Joy-Cons on macOS 13 and later, Stadia controllers, and any official Made-for-iPhone gamepad."
            ),
            HelpSection(
                heading: "What might need extra setup",
                steps: [
                    "8BitDo controllers: flip the mode switch on the back to A (Apple). See the 8BitDo guide for details.",
                    "Stadia controllers: update the controller using Google's Bluetooth update tool first.",
                    "Generic USB gamepads: these report as raw HID devices, which InputConfig reads directly. They appear under Connected Controllers in Settings."
                ]
            ),
            HelpSection(
                heading: "If a controller is not detected",
                body: "Open System Settings then Bluetooth or USB and confirm the controller is connected. Then click Refresh Controllers in InputConfig's controller popover. Most pads, fight sticks, and wheels that GameController does not support are still read directly as raw HID devices, including the DualShock 3 over USB and Logitech F-series pads with the switch on D. A controller that still does not appear is most likely in a vendor-specific mode a sandboxed app cannot read, such as the Xbox 360's wired protocol; try a different mode switch position if it has one."
            ),
        ]
    )

    static let eightBitDoMode = HelpGuide(
        id: "8bitdo-mode",
        title: "Using 8BitDo Controllers",
        category: "Troubleshooting",
        summary: "8BitDo controllers can run in several different modes. Apple mode gives the fullest native support and is the most reliable on a Mac, but InputConfig also reads XInput and DirectInput modes directly over raw HID, so most 8BitDo controllers still work for mapping in any mode and appear under Connected Controllers in Settings. If buttons are not registering, switch to Apple mode using the steps below.",
        sections: [
            HelpSection(
                heading: "Switching to Apple mode",
                steps: [
                    "Turn the controller off.",
                    "Flip the controller over and find the mode switch on the back. Most 8BitDo controllers have a small slider with the positions S, X, D, and A.",
                    "Slide the switch to the A position.",
                    "Turn the controller back on. The LEDs on most 8BitDo models will light up in a pattern that confirms the mode change.",
                    "Reconnect to your Mac. The controller should now appear in InputConfig with full button support."
                ]
            ),
            HelpSection(
                heading: "Mode reference",
                steps: [
                    "A = Apple mode (use this on Mac)",
                    "S = Nintendo Switch mode (partial Mac support)",
                    "X = XInput / Xbox mode (read directly over raw HID; works for mapping)",
                    "D = DirectInput mode (read directly over raw HID; works for mapping)"
                ]
            ),
            HelpSection(
                heading: "Controllers with no mode switch",
                body: "A few older or budget 8BitDo controllers do not have a physical mode switch. For those, hold the corresponding button while turning the controller on: hold B while pressing Start to enter Apple mode, hold Y while pressing Start for DirectInput, hold X while pressing Start for XInput, or hold A while pressing Start for Android. Check your model's manual to confirm."
            ),
            HelpSection(
                heading: "Ultimate 2C (wired) - special case",
                body: "The 8BitDo Ultimate 2C wired model has no Apple/MFi mode and no physical mode switch. InputConfig 1.3 and later can read this controller directly in its default XInput mode without any setup - just plug it in. If you are on an older version, switch the controller to Switch mode by holding Y while plugging in the USB cable; macOS Ventura+ recognizes Switch mode natively as a Nintendo Switch Pro controller."
            ),
            HelpSection(
                heading: "Update the firmware",
                body: "If you have updated to a recent firmware and the controller still does not connect, install the latest firmware from 8BitDo's website using their firmware tool. Apple mode support was added or improved in firmware updates released after early 2023."
            ),
            HelpSection(
                heading: "Supported models",
                body: "Models confirmed to work in Apple mode include the Pro 2, Ultimate (Bluetooth and 2.4G), SN30 Pro+, Pro, SN30 Pro, and Lite SE. Other models may work but are not officially supported by 8BitDo for Apple devices."
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

    static let midiOutput = HelpGuide(
        id: "midi-output",
        title: "MIDI Output",
        category: "Bindings",
        summary: "InputConfig can send MIDI messages to any music app on your Mac. Map buttons to notes, joysticks to continuous controllers, and triggers to pitch bend so your game controller works as a MIDI controller for Logic, Ableton, GarageBand, and similar.",
        sections: [
            HelpSection(
                heading: "How the virtual port works",
                body: "Whenever InputConfig is running, it creates a virtual MIDI source on your Mac named \"InputConfig\". Any DAW or MIDI app that lists MIDI inputs will see it as an available source. You do not need an IAC bus, a third-party app, or any extra setup."
            ),
            HelpSection(
                heading: "Connecting in a DAW",
                steps: [
                    "Open your DAW (Logic, Ableton, GarageBand, MainStage, Bitwig, etc.).",
                    "Find the MIDI input or external controller settings.",
                    "Enable \"InputConfig\" as a MIDI input source.",
                    "Arm or select a track that listens to that MIDI input.",
                    "Activate a InputConfig preset that contains MIDI bindings and start playing."
                ]
            ),
            HelpSection(
                heading: "MIDI Note bindings",
                body: "Use a Note binding to play a single MIDI note when a button is pressed and stop it when the button is released. Pick the note (C-1 through G9), velocity (how hard it strikes, 0 to 127), and channel (1 to 16). Great for mapping buttons to drum pads or a small keyboard layout across your controller's face buttons."
            ),
            HelpSection(
                heading: "MIDI CC bindings",
                body: "Control Change bindings are perfect for sliders and continuous parameters. Map a joystick axis to CC 1 (Modulation Wheel), CC 7 (Volume), CC 11 (Expression), or any other CC number. When Variable Sensitivity is on for the axis, the CC value smoothly follows how far the joystick is pushed."
            ),
            HelpSection(
                heading: "MIDI Pitch Bend bindings",
                body: "Pitch Bend is the wide whole-controller bend wheel. Map a thumbstick axis with positive and negative directions to pitch bend for natural up-and-down bending. The center position holds 8192 (no bend); maximum positive sends 16383, maximum negative sends 0."
            ),
            HelpSection(
                heading: "MIDI Program Change",
                body: "Program Change switches the receiving instrument to a different patch (sound). Map a button to Program 0-127 to instantly recall a synth sound, drum kit, or instrument bank. Many DAWs and hardware synths assign specific sounds to each program number."
            ),
            HelpSection(
                heading: "MIDI Transport",
                body: "Transport bindings send real-time playback commands to the DAW: Start (begin playback from the beginning), Stop, or Continue (resume from current position). Map one button per action and you have hardware transport control without leaving the DAW window."
            ),
            HelpSection(
                heading: "Stuck notes",
                body: "When you deactivate a preset, InputConfig automatically sends note-off for every note it currently has held. If something goes wrong and a note hangs anyway, deactivating and reactivating any preset will clear it. Most DAWs also have a global \"All Notes Off\" panic shortcut."
            ),
        ]
    )

    static let builtInExamples = HelpGuide(
        id: "built-in-examples",
        title: "Built-in Example Presets",
        category: "Getting Started",
        summary: "InputConfig ships with a curated library of example presets organized into five groups in the sidebar. Each one is a working starting point you can edit or copy.",
        sections: [
            HelpSection(
                heading: "Desktop & Productivity",
                body: "Drive macOS without touching the keyboard. Desktop Navigation maps the sticks to cursor and scroll plus common shortcuts. Web Browsing adds tab cycling and history navigation. Mouse + Scroll is a clean dual-stick mouse. Media Controller maps the face buttons to play/pause and volume. Presentation Remote drives Keynote-style slide navigation."
            ),
            HelpSection(
                heading: "Gaming: First-Person",
                body: "One FPS preset per controller family so you start with native button positions. FPS (PS5 DualSense), FPS (Xbox), FPS (Switch Pro), and FPS (8BitDo) each use WASD movement, mouse aim on the right stick, triggers for fire and ADS."
            ),
            HelpSection(
                heading: "Gaming: Genre",
                body: "Minecraft maps standard survival-mode controls (mine, place, sprint, hotbar). Fortnite covers building, editing, and shooting. Racing Game puts steering on the left stick and gas/brake on the triggers."
            ),
            HelpSection(
                heading: "MIDI & Creative",
                body: "Three musical presets sending to InputConfig's virtual CoreMIDI source. Pick InputConfig as input in GarageBand (or any DAW) to play them.",
                steps: [
                    "MIDI: DAW Performance - right stick drives pitch bend and mod wheel, triggers send CC 7 / CC 11, face buttons play a C major chord with light haptic.",
                    "MIDI: Drum Pad - face buttons trigger General MIDI kick, snare, closed hat, and open hat on channel 10, all with turbo enabled so you can roll fills by holding.",
                    "MIDI: Transport Control - A/B/X send Start/Stop/Continue messages to remote-control your DAW transport."
                ]
            ),
            HelpSection(
                heading: "Feature Showcases",
                body: "Six presets designed to demonstrate one advanced feature at a time. Open any of them and look at the binding settings to see how the feature is configured.",
                steps: [
                    "Variable Sensitivity - right stick uses Smooth curve, left stick uses Aggressive curve. Compare feel.",
                    "Deadzone Calibration - right stick has wide inner and outer deadzones, left stick is tight. Open Advanced > Calibrate to see the live ring.",
                    "Haptic Feedback - face buttons rumble at four intensities from gentle (A) to maximum (Y). DualSense or DualSense Edge required.",
                    "Spoken Feedback - face buttons each speak a different phrase. A and B go to Mac speakers, X and Y try the controller speaker.",
                    "Macros & Turbo - RB rapid-fires the space bar at 12 Hz. A runs a copy/switch-app/paste macro chain. LB repeats J three times.",
                    "Touchpad Mouse - finger 1 on the DualSense or DualShock 4 touchpad surface drives the mouse cursor. Finger 2 scrolls. Touchpad press is a left click."
                ]
            ),
            HelpSection(
                heading: "Editing or copying an example",
                body: "Examples are normal presets stored in your Application Support folder. Edit them directly, or right-click and Duplicate to keep the original untouched."
            ),
        ]
    )

    static let steamController = HelpGuide(
        id: "steam-controller",
        title: "Using the Valve Steam Controller",
        category: "Controllers",
        summary: "InputConfig supports the Steam Controller (wired and via the wireless USB dongle) by reading its raw HID reports directly. The controller doesn't speak Apple's MFi protocol, so it appears as a separate virtual slot in InputConfig.",
        sections: [
            HelpSection(
                heading: "Hardware support",
                body: "Valve Steam Controller (PID 0x1102 over USB and PID 0x1142 via the wireless dongle). The Steam Deck is a different device and is not handled by this helper."
            ),
            HelpSection(
                heading: "What we do under the hood",
                steps: [
                    "A bundled helper binary (SteamControllerHelper) opens the controller's vendor HID interface without seizing it.",
                    "We send two feature reports to disable 'lizard mode' - the controller's built-in keyboard / mouse emulation. Lizard mode hides the rich 64-byte input report we want.",
                    "We re-send the disable command every 800 ms; the controller re-enables lizard mode on a timeout if we stop.",
                    "The 64-byte input report is parsed into 23 buttons + 6 axes + gyro/accel, then streamed to the main app."
                ]
            ),
            HelpSection(
                heading: "Where it shows up",
                body: "When a Steam Controller is connected, it appears in the controller status bar and the preset detail's Controller list as 'Steam Controller'. In preset bindings it occupies the joystick index just past your last MFi controller (so if you have a DualSense in slot 0, the Steam Controller is slot 1)."
            ),
            HelpSection(
                heading: "Button index reference",
                steps: [
                    "0: RT digital  •  1: LT digital  •  2: RB  •  3: LB",
                    "4: Y  •  5: B  •  6: X  •  7: A",
                    "8: D-pad up  •  9: D-pad right  •  10: D-pad left  •  11: D-pad down",
                    "12: Back  •  13: Steam  •  14: Forward",
                    "15: Left grip paddle  •  16: Right grip paddle",
                    "17: Left pad click  •  18: Right pad click",
                    "19: Left pad touch  •  20: Right pad touch",
                    "21: Stick click  •  22: Stick active (sentinel bit, not a press)"
                ]
            ),
            HelpSection(
                heading: "Axis reference",
                body: "Axis 0/1 = left axis (stick when the user is using the analog stick, otherwise the left trackpad). Axis 2/3 = right trackpad. Axis 4/5 = analog triggers. Trackpad axes are scaled to [-1, 1]."
            ),
            HelpSection(
                heading: "Running alongside Steam",
                body: "InputConfig fights Steam over lizard mode if both are running with the Steam Controller plugged in. Quit Steam (or unbind the controller in Steam Settings) before using InputConfig if you see flicker."
            ),
        ]
    )

    static let dataPersistence = HelpGuide(
        id: "data-persistence",
        title: "Where Your Data Lives (and Why Updates Don't Erase It)",
        category: "Getting Started",
        summary: "Every preset, group, snapshot, statistic, touchpad calibration, and touchpad region you configure is stored inside the app's sandbox container. App Store updates only replace the app bundle; the container is left untouched, so nothing you've set up is lost when InputConfig updates.",
        sections: [
            HelpSection(
                heading: "Exact locations",
                body: "Open Settings > General > Reveal Data Folder to jump to the Application Support directory. The full path inside the sandbox container is roughly: ~/Library/Containers/com.inputconfig.app/Data/Library/Application Support/InputConfig/."
            ),
            HelpSection(
                heading: "What's where",
                steps: [
                    "presets/*.json - every preset you've created or imported, one file per preset",
                    "versions/<presetID>/*.json - automatic snapshots of each preset (the last 10 saves) used by the Previous Versions Revert button",
                    "groups.json - sidebar group order and names",
                    "stats.json - lifetime statistics, daily connection log, top inputs/presets",
                    "(Preferences plist) - touchpad calibration bounds, touchpad regions, tip jar count, one-shot group-seed flag"
                ]
            ),
            HelpSection(
                heading: "App Store updates",
                body: "When InputConfig is updated through the App Store, macOS replaces the app bundle inside /Applications and leaves the sandbox container alone. So everything above survives every update with no action required from you."
            ),
            HelpSection(
                heading: "Backups and migration to a new Mac",
                body: "Settings > General > Export Backup writes every preset, group, and stored preference into a single JSON file. Restore from Backup reads one back. This is also the easiest way to move your setup to another Mac."
            ),
            HelpSection(
                heading: "If you ever uninstall",
                body: "Drag the InputConfig app to the Trash from /Applications. The sandbox container stays in ~/Library/Containers until you manually remove it, so a reinstall picks up exactly where you left off. If you want a truly fresh start, also delete the container folder."
            ),
        ]
    )

    static let gyroscopeAim = HelpGuide(
        id: "gyroscope-aim",
        title: "Using the Controller's Gyroscope",
        category: "Bindings",
        summary: "Sony controllers with motion sensors (DualSense, DualSense Edge, DualShock 4) expose gyroscope rotation rate, accelerometer, and absolute attitude through Apple's Game Controller framework. InputConfig can bind any of these channels to mouse motion, keys, or anything else an axis can output. Nintendo Switch Pro and Joy-Cons report buttons and sticks on macOS, but their motion sensors are NOT exposed by the OS so they cannot drive gyro bindings.",
        sections: [
            HelpSection(
                heading: "Adding a motion binding",
                steps: [
                    "Edit a preset and add a new binding row.",
                    "Set the input type to Motion.",
                    "Pick the channel: Gyro Y (yaw rate) for left/right looking, Gyro X (pitch rate) for up/down, Gyro Z (roll rate) for tilt. Accelerometer X/Y/Z and the absolute Roll/Pitch/Yaw angles are also available.",
                    "Pick the half-axis: + means tilt forward / rotate one way, - means the opposite.",
                    "Pick the output: usually Mouse Motion in the matching direction, but anything works."
                ]
            ),
            HelpSection(
                heading: "Quick recipe: motion aim",
                body: "The built-in Showcase: Gyro Aim preset wires Gyro Y to mouse X and Gyro X to mouse Y with sensible defaults. Activate it and tilt the controller to move the cursor - the same feel as motion aim in Splatoon, Breath of the Wild, or Returnal."
            ),
            HelpSection(
                heading: "Drift and dead zones",
                body: "Stationary controllers report tiny non-zero gyro values because the sensors aren't perfectly calibrated. InputConfig applies a small dead zone by default (0.05 rad/s) to filter this. If the cursor drifts when you set the controller down, raise the binding's deadzone slider in Advanced."
            ),
            HelpSection(
                heading: "Compatibility",
                body: "Apple's Game Controller framework only exposes motion if the controller actually publishes it AND macOS has paired the motion service. Some Bluetooth pairings drop motion data - try a wired connection if the gyro doesn't seem to work. The Settings > Controllers tab shows whether motion is available for each connected device."
            ),
        ]
    )

    static let touchpadAsMouse = HelpGuide(
        id: "touchpad-as-mouse",
        title: "Using the DualSense / DualShock Touchpad as a Mouse",
        category: "Bindings",
        summary: "DualSense, DualSense Edge, and DualShock 4 have a multi-touch trackpad surface that InputConfig can map to mouse motion. The existing touchpad button (press) is unaffected.",
        sections: [
            HelpSection(
                heading: "How to bind it",
                steps: [
                    "Open a preset and add a new binding.",
                    "Set the input type to Touchpad.",
                    "Pick Finger 1 or Finger 2 (multi-touch is supported, so the two fingers can map to different outputs).",
                    "Pick the axis and direction: X+ means swipe right, X- means swipe left, Y+ means swipe down, Y- means swipe up.",
                    "Set the output to Mouse Motion in the matching direction. The Showcase: Touchpad Mouse preset shows a complete example."
                ]
            ),
            HelpSection(
                heading: "Coexistence with the touchpad button",
                body: "Pressing the touchpad continues to fire as button 13 in the existing bindings. The new touchpad-as-mouse handling reads the surface itself, separate from the click."
            ),
            HelpSection(
                heading: "How it works under the hood",
                body: "A small sandboxed helper (TouchpadHelper) bundled with the app opens the controller's HID device without seizing it, so the rest of InputConfig keeps working. The helper parses the Sony touchpad bytes from each input report and streams finger positions back to the app. It only runs while a preset that uses touchpad inputs is active."
            ),
        ]
    )

    static let presetGroups = HelpGuide(
        id: "preset-groups",
        title: "Organizing Presets in Groups",
        category: "Getting Started",
        summary: "Once you have several presets, group them into named folders in the sidebar so related presets stay together. Groups are purely organizational - they do not change how presets work.",
        sections: [
            HelpSection(
                heading: "Creating a group",
                steps: [
                    "Drag one preset on top of another in the sidebar. A prompt asks for a group name. Both presets become members of the new group.",
                    "Or click the plus button in the sidebar toolbar and choose New Group.",
                    "Or right-click any preset and pick Move to Group then New Group."
                ]
            ),
            HelpSection(
                heading: "Moving presets between groups",
                body: "Drag a preset onto a group header to add it to that group. Right-click a preset and choose Move to Group for an existing group, or Remove from Group to make it ungrouped again."
            ),
            HelpSection(
                heading: "Renaming and deleting groups",
                body: "Right-click a group header to rename or delete it. Deleting a group does not delete the presets inside - they just become ungrouped."
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
                body: "Open System Settings > Sound, then under Output pick your controller from the list. Audio from InputConfig will then play through the controller speaker."
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
                body: "InputConfig briefly resets the controller connection to send the new color. This takes about a second. Once the color is applied, the connection returns to normal."
            ),
        ]
    )
}
