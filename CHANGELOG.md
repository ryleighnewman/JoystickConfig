# Changelog

## 1.3

- Knob modes for MIDI dials: Dial mode treats the centre of the knob as zero,
  so scrolling and mouse motion speed up the further you turn, with a deadzone
  to stop at centre.
- Turn mode fires a nudge for every few steps of rotation, clockwise or
  counterclockwise, built for volume, brightness, and stepped scrolling.
- Both modes work with the sensitivity curves, deadzone settings, and variable
  speed the analog sticks already use.
- System volume as a fader: a new output that makes the Mac's volume follow a
  knob, the pitch wheel, aftertouch, or a controller trigger 1-to-1.
- Turn Step setting per binding: Fine, Normal, Coarse, or Chunky nudge
  sensitivity for Turn mode.
- The volume fader only takes over once you actually move the control, so
  activating a preset never jumps the volume to wherever a knob was left.
- New built-in preset "MIDI: Knob Deck" in MIDI & Creative: volume fader on
  CC 7, Dial scrolling on the mod wheel, Turn arrow nudges, pedal click, and
  pad keys, ready to remap.
- A new welcome-screen card and demo for MIDI devices as input.
- System Function outputs: bind anything to volume up / down, mute, play /
  pause and track skip, screen brightness, Mission Control, Launchpad,
  Spotlight, lock screen, the screenshot toolbar, running a Siri Shortcut,
  or opening any app or URL.
- New built-in preset "MIDI: Media Deck": pads and knobs running media
  keys, stepped volume, and brightness.
- A What's New popup appears once after each update with that version's
  changes.
- The YapToText shoutout moved to the bottom of the welcome screen, with a
  one-click App Store link.
- An About button on the welcome screen opens the redesigned About page:
  the story behind the app, the changelog, source code, and support.
- A new Accessibility area in Settings: app-wide text size, bold text,
  reduced transparency, and reduced motion, layered on top of the system
  settings.
- MIDI is now a full Live Visualizer template, switchable from the layout
  picker and automatic for MIDI presets: a seven-octave velocity-shaded
  keyboard with octave labels and bound-note dots, a named dial for every
  knob (Mod Wheel, Cutoff, Sustain...), knob-mode badges, pitch bend and
  aftertouch meters, a 16-channel activity strip, and a rolling event log
  with velocities. Everything renders at rest before a device is even
  connected, and every key and knob still clicks through to its bindings.
- Five new welcome-screen feature cards - Siri Shortcuts, Keyboard & Mouse
  as Input, Hold & Double-Tap, Per-App Auto-Switch, and Cursor Regions -
  with the grid reordered by importance.
- The version number shows in the menu bar popover, matching YapToText.

## 1.2.1

- Fixes MIDI devices not appearing as an option when creating a binding.
- MIDI now works with no game controller connected, so a MIDI keyboard or pad
  controller can drive your Mac on its own.
- Connected MIDI devices are listed by name when you pick an input, so you can
  confirm yours was found.
- Input groups are now called Input Device rather than Joystick, since a group
  can hold MIDI, keyboard, and mouse bindings too.
- A group no longer warns about a missing controller when nothing in it needs one.
- The scan panel now tells you that you can play a note or twist a knob to map it.

## 1.2

- MIDI devices can now be used as an input: bind notes, pads, knobs, the pitch
  wheel, the sustain pedal, and aftertouch to keys, clicks, macros, or anything
  else.
- DualSense Edge extra buttons: the back paddles, both FN buttons, and mute are
  now bindable like any other input, over Bluetooth and USB.
- Light bar colors now work over Bluetooth: preset colors, the RGB cycle, and
  brightness all reach the controller wirelessly.
- New help guides for MIDI input and the DualSense Edge extra buttons.
- A changelog you can read inside the app, from the welcome screen or About.
- More reliable controller data reading behind the scenes, with an automatic
  fallback when a Bluetooth session goes quiet.

## 1.1.1

- Fixes a crash that prevented InputConfig from launching on macOS 14 Sonoma.

## 1.1

- 431 built-in presets, over 300 of them new: games, creative and productivity
  apps, and accessibility workflows including VoiceOver Navigation, Numeric
  Keypad, Menu Bar and Dock, Emulator, and Comic Reader.
- Much broader controller compatibility: DualShock 3, Logitech F-series in D
  mode, fight sticks, multi-mode pads, and wheels now connect through the
  rebuilt device support, with correct d-pad handling on far more controllers.
- Keyboard shortcut outputs with modifiers (Cmd+C and friends) now fire as real
  combos.
- Fixed stuck mouse buttons after sleep, stuck MIDI controllers and pitch bend
  after stopping a preset, and edits to a running preset not applying until
  reactivation.
- Crash recovery now fully restores your active preset, including restarting the
  mapping engine.
- Macros: Toggle plus Macro works as documented, the editor shows macro state
  accurately, and duplicating a binding keeps every setting.
- VoiceOver: the input scan overlay announces itself and speaks what it
  detected, and the binding editor controls are labeled.
- Live Visualizer: the zoomed controller map now stays cleanly inside its panel.
- Faster and lighter: large reductions in per-frame work across the input path
  and the interface.

## 1.0

- Initial release.
