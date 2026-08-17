# Changelog

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
