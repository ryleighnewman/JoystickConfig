# JoystickConfig

Map any game controller to keyboard and mouse on macOS.

## Overview

JoystickConfig lets you use any game controller as a keyboard and mouse on your Mac. Plug in your controller, pick a preset, and go. Or build your own from scratch.

Works with DualSense (PS5), DualSense Edge, DualShock 4 (PS4), Xbox Wireless, and any MFi or HID-compatible gamepad. No drivers needed.

![Main View](screenshots/main_view.png)

The main view shows all your presets on the left with a live status bar for connected controllers. You can see battery level, button count, axis count, and light bar status at a glance. Activate any preset with one click. The bottom panel is a live logger that shows engine activity, connected controllers, and input events in real time at 120Hz.

![Binding Editor](screenshots/binding_editor.png)

The binding editor is where you set up your mappings. Hit Scan to detect a button press or axis movement from your controller, then assign it to a keyboard key, mouse button, mouse motion, or scroll wheel. Every binding has its own output type picker and value selector. You can add multiple outputs per input, reorder bindings with drag and drop, and duplicate or delete them individually.

![Advanced Options](screenshots/advanced_options.png)

Each binding has advanced options you can expand. Set per-axis deadzones with a slider, invert axes, and pick a sensitivity curve (linear, smooth, or aggressive). Toggle mode lets you press once to hold and press again to release. Turbo mode gives you rapid fire at a custom rate. You can set repeat count and delay per binding. The macro editor lets you chain multiple keystrokes in sequence with custom wait and hold times per step.

## Features

- Map buttons, triggers, joysticks, and d-pad to keyboard keys
- Map joysticks to mouse movement and scroll wheel with adjustable speed
- Scan for controller inputs directly from the editor
- Macro sequences with custom wait and hold timing per step
- Turbo (rapid fire) at adjustable rates
- Toggle mode for hold-on-press, release-on-press behavior
- Per-axis deadzones, inversion, and sensitivity curves
- Repeat count and delay per binding
- Multiple outputs per input
- DualSense light bar color control
- Unlimited presets with one-click activation
- Import, export, and share preset files
- Convert presets between controller types (DualSense, PlayStation, Xbox)
- Sort and reorder bindings
- Live input monitor and debug log
- 120Hz input polling
- Native macOS app built with SwiftUI

## Supported Controllers

- PlayStation DualSense (PS5) and DualSense Edge
- PlayStation DualShock 4 (PS4)
- Xbox Wireless Controller
- Any MFi or HID-compatible gamepad

## Requirements

- macOS 14.0 or later
- Accessibility permission (for keyboard and mouse simulation)

## Building

1. Open `JoystickConfig.xcodeproj` in Xcode 16+
2. Select your team in Signing & Capabilities
3. Build and run

## License

MIT License. See [LICENSE](LICENSE) for details.

## Privacy

JoystickConfig does not collect any data. See [PRIVACY.md](PRIVACY.md).

## Contact

Questions, bugs, or feature requests? Reach out at [ryleighnewman.com](https://ryleighnewman.com).
