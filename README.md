# InputConfig

InputConfig is a free, open-source input mapper for macOS. It turns any game
controller, keyboard, mouse, or MIDI device into your Mac's input: browse the web
from a gamepad, run your Mac from a MIDI knob box, play games that never supported
controllers, or replace a keyboard entirely if using one is difficult.

Works with PS5 DualSense and DualSense Edge, DualShock 4, Xbox Wireless, Switch Pro,
8BitDo, the PlayStation Access Controller, MIDI keyboards and pad controllers, and any
HID-compatible gamepad. No drivers, no subscription, no account.

<a href="https://apps.apple.com/us/app/inputconfig/id6777759147?mt=12"><img src="https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-mac-app-store/black/en-us" alt="Download on the Mac App Store" height="56"></a>

## Overview

Plug in your device, pick a preset, and go. Or build your own from scratch: every
button, trigger, stick, key, knob, and pad can send keys, clicks, mouse motion,
scroll, macros, MIDI, spoken phrases, or a system function like volume, brightness,
or a Siri Shortcut.

It is not just for game controllers. Your Mac keyboard, a second keyboard, extra
mouse buttons, the trackpad (including Force Touch pressure), regions of the screen,
and full MIDI gear all work as inputs too.

## What's new in 1.3

- MIDI devices as input, everywhere: bind notes, pads, knobs, the pitch wheel, the sustain pedal, and aftertouch to anything, with no game controller connected
- Knob modes for MIDI dials: Switch fires past halfway, Dial speeds up the further you turn from centre, Turn nudges once per step, with per-binding step sensitivity
- System Function outputs: volume, mute, media keys, brightness, Mission Control, Launchpad, Spotlight, lock screen, the screenshot toolbar, Siri Shortcuts, and opening any app or URL
- System volume as a fader: the Mac's volume follows a knob 1-to-1, engaging only once you actually move it
- The Live Visualizer gained a full MIDI Instrument template: a velocity-shaded keyboard, named knob dials, pitch bend and aftertouch meters, a channel strip, and a live event log
- Two new built-in presets (MIDI: Knob Deck and MIDI: Media Deck), new welcome-screen feature demos, and a What's New popup after updates
- An Accessibility area in Settings: app-wide text size, bold text, reduced transparency, and reduced motion
- A redesigned About page and a refreshed welcome screen

Full release history in [CHANGELOG.md](CHANGELOG.md). This section tracks the latest release.

## A tour

![Turn literally anything into your Mac's input](Marketing/posters/01-hero.jpg)

Open InputConfig and everything it can do is on one screen. Controllers, keyboards,
mice, trackpads, and MIDI gear go in; keys, mouse, macros, MIDI, system functions,
and Siri Shortcuts come out. Hundreds of presets ship with it, sorted into folders
you can name and colour.

![Press a control, bind it](Marketing/posters/02-scan.jpg)

Scanning maps any input the instant you touch it. No manual codes, no guesswork,
and it works for controllers, MIDI gear, and your Mac's own keyboard and trackpad.

![Map any button to anything](Marketing/posters/03-map.jpg)

Every button, trigger, stick, key, and knob can send a key, a click, mouse motion,
scroll, a macro, MIDI, or a system function, across every device you own at once.

![Fine-tune every binding](Marketing/posters/04-advanced.jpg)

Turbo, macros, hold and double-tap actions, haptics, and spoken phrases are all
available on a single control at the same time, with repeat counts and timing
windows tuned right in the row.

![Built for accessibility](Marketing/posters/05-accessibility.jpg)

Drive your whole Mac from a single stick. One-stick driving steers, accelerates,
brakes, and shifts from one control, and it outputs keyboard and mouse, so it works
in games that never planned for it. Built with the PlayStation Access Controller
and other adaptive hardware in mind.

![Outputs that run your Mac](Marketing/posters/06-outputs.jpg)

One pad press can change the volume, skip a track, dim the display, open Mission
Control, lock the screen, or run a whole Siri Shortcut. Every binding shows exactly
what it sends.

![See every input, live](Marketing/posters/07-visualizer.jpg)

The Live Visualizer mirrors your controller and your MIDI gear in real time. Sticks,
triggers, keys, and knobs light up as you play, and clicking any control jumps
straight to its mapping.

![Touchpad support, done right](Marketing/posters/08-touchpad.jpg)

Calibrate a controller touchpad so swipes feel uniform, then carve it into tap zones
that fire their own bindings, with multiple fingers tracked independently.

![Dial in the deadzone, aim with precision](Marketing/posters/09-precision.jpg)

Tune the inner and outer deadzone on every stick and trigger with a live plot, so
drift disappears and full travel stays. Bind gyroscope rotation to the mouse for
motion aim in any app, with live sensor readings and a resting-zero calibration.

![Free, open source, yours](Marketing/posters/10-about.jpg)

No accounts, no tracking, no locked features. Built by one person who needed it,
shaped by the community that uses it.

## How it compares

| | InputConfig | Joystick Mapper | Gamepad Companion | Enjoyable | Karabiner-Elements |
|---|---|---|---|---|---|
| Cost | Free | Paid | Paid | Free | Free |
| Open source | Yes, MIT | No | No | Yes | Yes |
| Game controllers | Yes | Yes | Yes | Yes | No, keyboards only |
| MIDI keyboards and pads as input | Yes | No | No | No | No |
| Mac keyboard/mouse/trackpad as input | Yes | No | No | No | Keyboard only |
| DualSense Edge paddles and extras | Yes | No | No | No | No |
| System functions and Siri Shortcuts | Yes | No | No | No | Limited |
| Per-app preset switching | Yes | No | No | No | Yes |
| Macros, turbo, tap and hold | Yes | Limited | Limited | No | Limited |
| MIDI output | Yes | No | No | No | No |
| Gyroscope and motion | Yes | No | No | No | No |
| Light bar control | Yes | No | No | No | No |
| Still updated | Yes | Rarely | Rarely | No | Yes |

Checked August 2026. Some of these have been around far longer than mine and are good
tools. Check for yourself before you switch.

## Everything it does

### Input sources

- Every button, trigger, joystick, and D-pad on any MFi or HID-compatible gamepad
- DualSense Edge extras: both back paddles, both FN buttons, and the mute button, over USB and Bluetooth
- Controller touchpads: cursor control, multi-finger tracking, tap regions, and gestures, with per-pad calibration
- Gyroscope, accelerometer, and absolute attitude on motion-capable controllers
- MIDI notes and pads, CC knobs, sliders, and pedals, the pitch wheel, channel aftertouch, and Program Change, from any MIDI device over USB or Bluetooth
- Three knob modes for MIDI dials: Switch (fires past halfway), Dial (speed grows from centre, like a stick), and Turn (a nudge per step of rotation, built for endless encoders)
- Per-binding MIDI channel and device filters, so two keyboards stay independent
- Your Mac keyboard, a second keyboard, and extra mouse buttons as inputs, captured per device
- Force Touch trackpad pressure and Force Click
- Cursor regions: areas of the screen that act as inputs when the pointer enters
- Stick regions: directional zones on any stick with their own bindings

### Outputs

- Keyboard keys, including full modifier combos (Cmd+Shift+3 and friends fire as real chords)
- Type whole words or phrases from a single press
- Mouse buttons, analog mouse motion, smooth scrolling, and single scroll steps
- Macro sequences with custom timing, chord steps that hold one key while tapping others, and interrupt-on-release
- MIDI out to your DAW through a virtual port: notes with velocity, CC, pitch bend, Program Change, and transport (start, stop, continue)
- Spoken phrases through the Mac speakers or the controller's own speaker
- Haptic feedback with adjustable strength
- App actions: switch presets, jump to a specific preset, pause and resume output, all from the controller

### System functions

- Volume up, volume down, and mute, in the same steps as the keyboard keys
- System volume as a fader: the Mac's level follows a knob's position 1-to-1, and only takes over once you actually move it
- Play/pause, next track, and previous track, as real media keys
- Screen brightness up and down
- Mission Control, Launchpad, Spotlight, lock screen, and the screenshot toolbar
- Run any Siri Shortcut by name, picked from a list of your installed Shortcuts, without stealing focus
- Open any app or any URL, from https links to app schemes

### Per-binding control

- Toggle mode: press once to latch, press again to release
- Turbo with an adjustable rate, and repeat counts with custom delays
- Hold actions and double-tap actions, each with their own outputs and timing windows
- Inner and outer deadzones with a live visual calibrator on every stick and trigger
- Axis inversion and three sensitivity curves: linear, smooth, aggressive
- Variable sensitivity: trigger pressure and stick depth scale the output speed
- Stacked outputs: one input firing several outputs in parallel
- A note field on every binding, so a preset explains itself

### Presets

- Hundreds of built-in presets: adaptive controllers, desktop navigation, web browsing, media control, popular games, MIDI and creative work, and Mac apps
- Smart Preset Maker builds a tailored preset from a few questions
- Folders with names and colours, and unlimited presets of your own
- Per-app auto-switch: presets activate themselves when their app comes to the front
- Per-preset automation: launch an app or URL on activate, confine the cursor, auto-recenter, hide the pointer
- Import, export, and share presets, and convert them between controller types
- A global keyboard shortcut to toggle the most recent preset from anywhere
- Crash recovery restores your active preset, engine and all

### Live Visualizer

- A real-time mirror of every connected device, one panel per slot
- Switchable layouts per slot: controller, keyboard, touchpad, mouse, or MIDI instrument, with auto-detection from the bindings
- The MIDI instrument: a seven-octave velocity-shaded keyboard, a named dial for every knob (Mod Wheel, Cutoff, Sustain and the rest), knob-mode badges, pitch bend and aftertouch meters, a 16-channel activity strip, and a rolling event log
- Click any control to jump straight to its binding in the editor
- Drag-to-rearrange widget layouts, saved per controller model, plus zoom and pan

### Accessibility

- One-stick driving: steer, accelerate, brake, and shift from a single stick
- App-wide text size, bold text, reduced transparency, and reduced motion, layered on top of the system settings
- VoiceOver support in the scan overlay and binding editor
- Built-in presets for the PlayStation Access Controller and adaptive setups
- Deadzone and sensitivity tuning that matters for tremor and limited range of motion

### The app

- Light bar colors per preset with a full RGB picker, brightness control, and an RGB cycle, over USB and Bluetooth
- Battery level and connection state for every controller
- Lifetime usage statistics, kept entirely on your Mac
- A changelog inside the app and a What's New popup after updates
- More than twenty built-in help guides and a guided Quick Start tour
- Menu bar control with the running version, plus Dock-only and menu-bar-only modes
- Adjustable polling rate from 30 to 240 Hz, with an automatic battery saver
- Available in 12 languages
- Sandboxed, no network access, no telemetry

100% free.

## Supported controllers

- PlayStation Access Controller (and other adaptive hardware)
- PlayStation DualSense (PS5) and DualSense Edge, including the Edge's paddles and extra buttons
- PlayStation DualShock 4 (PS4) and DualShock 3
- Xbox Wireless Controller (One, Series X|S)
- Nintendo Switch Pro Controller and Joy-Cons
- 8BitDo controllers (Pro 2, Ultimate, SN30 Pro+, and more)
- Steam Controller, Stadia Controller, Logitech F-series, fight sticks, and wheels
- Any MFi or HID-compatible gamepad
- MIDI keyboards, pad controllers, knob boxes, and control surfaces
- Your Mac keyboard, mouse, and trackpad

## Questions people ask

**How do I use a PS5 or Xbox controller as a keyboard and mouse on Mac?**
Install InputConfig, plug in or pair the controller, pick a preset, and press Activate.
macOS will ask for Accessibility permission the first time, which is what lets any app send
keystrokes and mouse movement.

**Can I use a MIDI keyboard or pad controller to control my Mac?**
Yes, and it needs no game controller alongside it. Notes and pads act like buttons,
knobs get three modes (Switch, Dial, Turn), the sustain pedal is a switch, and a knob
bound to System Volume becomes a hardware volume fader. The built-in MIDI: Knob Deck
and MIDI: Media Deck presets are ready to remap.

**Can I map the DualSense Edge back paddles and FN buttons?**
Yes. The Edge's back paddles, both FN buttons, and the mute button are bindable like
any other input, over both USB and Bluetooth.

**Can a button run a Siri Shortcut or change the volume?**
Yes. System Functions are outputs like any other: volume, mute, media keys,
brightness, Mission Control, lock screen, the screenshot toolbar, any Siri Shortcut
by name, or opening any app or URL.

**Is there a free alternative to Joystick Mapper or Gamepad Companion?**
This is one. InputConfig is free with nothing locked, and the source is public under MIT.

**Can I use a controller instead of a keyboard and mouse entirely?**
Yes, that is the point. There are built-in presets for desktop navigation, web browsing,
and media control, plus presets built for adaptive controllers. You can map cursor zones,
type whole phrases from one button, and switch presets automatically per app.

**Does it work with the PlayStation Access Controller or the Xbox Adaptive Controller?**
Yes, along with anything else that presents as an MFi or HID gamepad. There are presets
built for adaptive setups, and one-stick driving lets a single stick handle steering,
throttle, braking, and gear changes. Accessibility is why the app exists, not an
afterthought.

**Do I need drivers?**
No. Connect the controller by USB or Bluetooth and macOS handles the rest. MIDI
devices are found automatically too.

**Can I map a controller for a game that has no controller support?**
Yes. Map the buttons and sticks to whatever keys and mouse motion the game expects, and it
sees a normal keyboard and mouse.

**Is it really free?**
Yes. No paid tier, no trial, no locked features. There is a tip jar in the app that unlocks
nothing.

## Requirements

- macOS 14.0 or later
- Accessibility permission (for keyboard and mouse simulation)

## Building

1. Open `InputConfig.xcodeproj` in Xcode 26 or later
2. Select your team in Signing & Capabilities
3. Build and run

## License

MIT License. See [LICENSE](LICENSE) for details.

## Privacy

InputConfig does not collect any data. See [PRIVACY.md](PRIVACY.md).

## Contact

Questions, bugs, or feature requests? Reach out at [ryleighnewman.com](https://ryleighnewman.com).
