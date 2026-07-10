import SwiftUI

/// Identifies which feature the welcome page just opened. Used to drive the
/// `FeatureDemoView` body and to look up the matching example preset.
enum FeatureDemoKind: String, CaseIterable, Identifiable {
    // Ordered as a guided tour: the core idea first, then tuning, then
    // advanced mapping, then alternate inputs, feedback, the controller LED,
    // creative MIDI output, per-preset automation, and finally usage stats.
    case keyboardMouse
    case controllers
    case variableSensitivity
    case deadzone
    case toggleMode
    case macros
    case stackedOutputs
    case touchpad
    case gyro
    case haptic
    case speech
    case lightBar
    case midi
    case midiCC
    case autoLaunch
    case stats

    var id: String { rawValue }

    /// Stable key used to look up the matching example preset by name.
    var presetKey: String? {
        switch self {
        case .variableSensitivity: return "variable_sensitivity"
        case .deadzone:            return "deadzone"
        case .haptic:              return "haptic"
        case .speech:              return "speech"
        case .macros:              return "macros"
        case .touchpad:            return "touchpad"
        case .midi:                return "midi"
        case .gyro:                return "gyro"
        case .toggleMode:          return "toggle_mode"
        case .stackedOutputs:      return "stacked_outputs"
        case .autoLaunch:          return "auto_launch"
        case .midiCC:              return "midi_cc"
        case .keyboardMouse:       return "keyboard_mouse"
        // No directly-matching showcase preset for these; their CTA opens the
        // right place instead (see `cta`).
        case .lightBar, .controllers, .stats: return nil
        }
    }

    /// What the demo's call-to-action button does. Mapping features open their
    /// matching example preset; the three that aren't presets open the right
    /// place instead, so every card has a working button.
    enum CTA: Equatable {
        case preset(String)   // jump to the example preset with this display name
        case statistics       // open the Statistics dashboard
        case settings         // open Settings
    }
    var cta: CTA {
        switch self {
        case .stats:                  return .statistics
        case .lightBar, .controllers: return .settings
        default:
            if let key = presetKey, let name = ExamplePresets.demoPresetNames[key] {
                return .preset(name)
            }
            return .settings
        }
    }

    var title: String {
        switch self {
        case .keyboardMouse:       return "Keyboard & Mouse"
        case .midi:                return "MIDI Output"
        case .variableSensitivity: return "Variable Sensitivity"
        case .deadzone:            return "Deadzone Calibration"
        case .macros:              return "Macros & Turbo"
        case .haptic:              return "Haptic Feedback"
        case .speech:              return "Spoken Feedback"
        case .lightBar:            return "Light Bar Control"
        case .controllers:         return "Wide Controller Support"
        case .touchpad:            return "Touchpad Mouse"
        case .gyro:                return "Gyroscope Motion"
        case .stats:               return "Lifetime Statistics"
        case .toggleMode:          return "Toggle Mode"
        case .stackedOutputs:      return "Stacked Outputs"
        case .autoLaunch:          return "Auto-Launch + Cursor Confine"
        case .midiCC:              return "MIDI CC Dials"
        }
    }

    var explanation: String {
        switch self {
        case .keyboardMouse:
            return "Every button, trigger, and stick can drive any keyboard key, mouse button, mouse motion, or scroll wheel. Bindings happen at the system level so they work in every app on macOS."
        case .midi:
            return "InputConfig publishes a virtual CoreMIDI source. Open GarageBand, Logic, Ableton, Reaper, or any DAW; pick InputConfig as the input; and the controller starts driving notes, CC, pitch bend, program change, and transport messages."
        case .variableSensitivity:
            return "Trigger pressure and joystick depth scale output speed so light inputs give precise control and full presses accelerate. Three response curves are built in: Linear, Smooth (exponential), and Aggressive (square-root). Pick per binding for how you want triggers and sticks to feel - racing-game throttle vs. FPS aim vs. instant-snap menu navigation."
        case .deadzone:
            return "Tune the inner deadzone to ignore stick drift and the outer deadzone so you reach full speed without bottoming the stick. The live calibration ring shows your stick position in real time."
        case .macros:
            return "Chain keystrokes with custom timing per step, or set Turbo on any button to rapid-fire it at a configurable rate. Macros can mix any output type, including MIDI."
        case .haptic:
            return "Bindings on DualSense and DualSense Edge can fire haptic feedback when they trigger. Pick an intensity per binding so important actions feel bigger."
        case .speech:
            return "Speak a custom phrase out loud when a binding fires. Choose Mac speakers or, where supported, the controller's built-in speaker."
        case .lightBar:
            return "Set the DualSense light bar to a custom color, dim or bright, or run an RGB cycle. Configured in Settings; runs through a sandboxed helper that uses Sony's HID color report."
        case .controllers:
            return "DualSense, DualSense Edge, DualShock 4, Xbox One / Series, Switch Pro, Joy-Cons, Stadia, 8BitDo Pro 2 / Ultimate / SN30 Pro+, and any MFi gamepad."
        case .touchpad:
            return "DualSense and DualShock 4 touchpad surfaces drive the mouse cursor. The touchpad press still works as a button. Multiple fingers map independently, so finger one can move the cursor while finger two scrolls."
        case .gyro:
            return "Controllers with motion sensors (DualSense, DualSense Edge, DualShock 4, Switch Pro, Joy-Con) expose gyroscope rotation rate, accelerometer, and absolute attitude. Bind any of them like a half-axis. The classic recipe: gyro yaw drives mouse X, gyro pitch drives mouse Y - motion aim, free across every app."
        case .stats:
            return "Every button press, mouse motion, scroll tick, MIDI event, and macro execution is counted locally. The Statistics window shows your most-used inputs and presets, daily connection history, and total time spent mapping. Nothing is sent over the network - the entire dataset lives in your sandbox container."
        case .toggleMode:
            return "Flip a binding from 'hold while pressed' to 'press once to latch on, press again to release'. Perfect for sticky modifiers (Shift / Cmd that you can park), push-to-talk that you can leave on, or auto-run W in any game."
        case .stackedOutputs:
            return "Wire one input to multiple outputs in parallel - a key AND a mouse click AND a MIDI note AND a spoken phrase, all firing simultaneously. Different from a macro (which is a sequence with delays); stacked outputs are simpler to debug and faster to author."
        case .autoLaunch:
            return "Each preset has its own Automation & Gaming Utilities panel. Activating the preset can auto-launch an app (e.g. Steam, your DAW, a specific game), confine the cursor away from screen edges, auto-recenter it, and hide the system pointer - all turned off when you deactivate. Per-game settings, never global."
        case .midiCC:
            return "Bind axes (sticks, triggers) to continuous MIDI Control Change values. Sticks become soft modulation knobs for filter cutoff, expression, channel volume, pan, anything CC-mappable in your DAW. Different from MIDI Notes - CC sends a 0-127 value every poll, perfect for sweeps and automation."
        }
    }
}

/// Modal that opens from a welcome-page card. Shows an animated demo of the
/// feature and (when applicable) a button that loads a matching example
/// preset in the sidebar.
struct FeatureDemoView: View {
    let kind: FeatureDemoKind
    let onJumpToPreset: (String) -> Void
    let onOpenStatistics: () -> Void
    let onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                IconView(name: iconName, glyphHeight: 25)
                    .font(.system(size: 32))
                    .iconTint(tint)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(.title3.weight(.semibold))
                    Text(kind.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider()

            // Fill the space between the header and the action row so the demo
            // sits centered in the body instead of everything bunching up in
            // the middle, and the buttons stay pinned to the bottom.
            demoSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Close on the left, primary "Take me..." on the right. The CTA has
            // its focus ring suppressed so it doesn't open pre-selected.
            HStack {
                Button("Close") { dismiss() }
                    .buttonStyle(.solidSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                ctaButton
                    .focusEffectDisabled()
            }
        }
        .padding(22)
        .frame(width: 560, height: 460)
    }

    /// The call-to-action button. Closing the demo sheet and presenting the
    /// destination is the parent's job (see ContentView), so these only invoke
    /// the relevant closure; the parent dismisses then routes.
    @ViewBuilder
    private var ctaButton: some View {
        switch kind.cta {
        case .preset(let name):
            Button { onJumpToPreset(name) } label: {
                Label("Take me to an example preset", systemImage: "arrowshape.right.fill")
            }
            .buttonStyle(GlassCTAButton(tint: tint))
        case .statistics:
            Button { onOpenStatistics() } label: {
                Label("Open Statistics", systemImage: "chart.bar.fill")
            }
            .buttonStyle(.solid)
        case .settings:
            Button { onOpenSettings() } label: {
                Label("Open Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(.solid)
        }
    }

    private var tint: Color {
        switch kind {
        case .keyboardMouse:       return .orange
        case .midi:                return .pink
        case .variableSensitivity: return .blue
        case .deadzone:            return .green
        case .macros:              return .yellow
        case .haptic:              return .purple
        case .speech:              return .indigo
        case .lightBar:            return .red
        case .controllers:         return .cyan
        case .touchpad:            return .mint
        case .gyro:                return .teal
        case .stats:               return .brown
        case .toggleMode:          return .orange
        case .stackedOutputs:      return .blue
        case .autoLaunch:          return .green
        case .midiCC:              return .purple
        }
    }

    private var iconName: String {
        switch kind {
        case .keyboardMouse:       return "keyboard"
        case .midi:                return "music.note.list"
        case .variableSensitivity: return "slider.horizontal.below.rectangle"
        case .deadzone:            return "scope"
        case .macros:              return "bolt.fill"
        case .haptic:              return "waveform"
        case .speech:              return "speaker.wave.2.fill"
        case .lightBar:            return "light.beacon.max.fill"
        case .controllers:         return "gamecontroller.fill"
        case .touchpad:            return "rectangle.and.hand.point.up.left.fill"
        case .gyro:                return "gyroscope"
        case .stats:               return "chart.bar.fill"
        case .toggleMode:          return "switch.2"
        case .stackedOutputs:      return "square.stack.3d.up.fill"
        case .autoLaunch:          return "app.badge.fill"
        case .midiCC:              return "dial.high.fill"
        }
    }

    @ViewBuilder
    private var demoSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
            switch kind {
            case .keyboardMouse:       KeyboardMouseDemo()
            case .midi:                MidiDemo()
            case .variableSensitivity: VariableSensitivityDemo()
            case .deadzone:            DeadzoneDemo()
            case .macros:              MacrosDemo()
            case .haptic:              HapticDemo()
            case .speech:              SpeechDemo()
            case .lightBar:            LightBarDemo()
            case .controllers:         ControllersDemo()
            case .touchpad:            TouchpadDemo()
            case .gyro:                GyroDemo()
            case .stats:               StatsDemo()
            case .toggleMode:          ToggleModeDemo()
            case .stackedOutputs:      StackedOutputsDemo()
            case .autoLaunch:          AutoLaunchDemo()
            case .midiCC:              MidiCCDemo()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }
}

// MARK: - Shared demo building blocks

/// Compact "input button" widget that visibly depresses when `pressed` is
/// true. Shared across the demos that follow the `input → arrow → output`
/// pattern so every visualization tells the same story consistently.
@ViewBuilder
private func inputBlock(label: String, pressed: Bool, tint: Color) -> some View {
    VStack(spacing: 6) {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(pressed ? tint.opacity(0.6) : Color.secondary.opacity(0.18))
            RoundedRectangle(cornerRadius: 12)
                .stroke(pressed ? tint : Color.secondary.opacity(0.4),
                        lineWidth: pressed ? 2 : 1)
            Image(systemName: "circle.fill")
                .font(.system(size: pressed ? 22 : 26))
                .foregroundStyle(pressed ? .white : tint.opacity(0.7))
        }
        .frame(width: 56, height: 56)
        .scaleEffect(pressed ? 0.92 : 1)
        .animation(.easeOut(duration: 0.08), value: pressed)

        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .frame(width: 70)
}

/// Horizontal arrow with a flowing gradient that brightens when `active`
/// is true. Visually conveys "input traveling to output" across the demo.
@ViewBuilder
private func gradientArrow(active: Bool, tint: Color) -> some View {
    TimelineView(.animation) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        let flow = active ? (sin(t * 4) + 1) / 2 : 0.0

        HStack(spacing: 0) {
            // Tail: a thin bar with the moving gradient.
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 6)
                Capsule()
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.2),
                                 tint.opacity(0.4 + flow * 0.5),
                                 tint.opacity(0.8 + flow * 0.2)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: active ? 70 : 0, height: 6)
                    .animation(.easeOut(duration: 0.15), value: active)
            }
            .frame(width: 70)
            // Head: arrowhead that fades in when active.
            Image(systemName: "arrowtriangle.right.fill")
                .foregroundStyle(active ? tint : tint.opacity(0.25))
                .font(.system(size: 18))
                .scaleEffect(active ? 1 : 0.85)
        }
        .frame(width: 90)
    }
}

// MARK: - Demo: Keyboard & Mouse

private struct KeyboardMouseDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 4) / 4
            let angle = phase * 2 * .pi
            // Stick thumb traces a slow circle.
            let stickRadius: CGFloat = 28
            let thumbX = cos(angle) * stickRadius
            let thumbY = sin(angle) * stickRadius
            // Cursor mirrors the stick at a larger scale.
            let cursorX = cos(angle) * 90
            let cursorY = sin(angle) * 60

            HStack(spacing: 32) {
                // Stick visualization
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 80, height: 80)
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 18, height: 18)
                        .offset(x: thumbX, y: thumbY)
                    Text("Stick")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .offset(y: 56)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                // Mouse cursor on a tiny "desktop"
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 220, height: 140)
                    Image(systemName: "cursorarrow.rays")
                        .font(.title2)
                        .iconTint(.orange)
                        .offset(x: cursorX, y: cursorY)
                }
            }
        }
    }
}

// MARK: - Demo: MIDI

private struct MidiDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let beat = Int(t.truncatingRemainder(dividingBy: 1.6) / 0.2) % 8
            // Three DAW icons rotate every ~2 seconds.
            let dawIndex = Int(t.truncatingRemainder(dividingBy: 6) / 2)
            let daws: [(String, String, Color)] = [
                ("waveform.path", "GarageBand", .pink),
                ("waveform", "Logic Pro", .orange),
                ("music.mic", "Ableton", .blue)
            ]
            let daw = daws[dawIndex % daws.count]

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    // Flying music notes that telegraph "MIDI traveling out."
                    ForEach(0..<3, id: \.self) { i in
                        let offset = (t + Double(i) * 0.4)
                            .truncatingRemainder(dividingBy: 1.2) / 1.2
                        Image(systemName: i == 0 ? "music.note" : (i == 1 ? "music.quarternote.3" : "music.note.list"))
                            .font(.title3)
                            .foregroundStyle(.pink.opacity(0.85))
                            .offset(y: -CGFloat(offset) * 6)
                            .opacity(1 - offset * 0.7)
                    }
                    Image(systemName: "arrow.right")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: daw.0)
                            .font(.title)
                            .foregroundStyle(daw.2)
                        Text(daw.1)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .id(daw.1)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.4), value: daw.1)
                    }
                }
                // 8 piano-key boxes light up in sequence.
                HStack(spacing: 3) {
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i == beat ? Color.pink : Color.secondary.opacity(0.18))
                            .frame(width: 22, height: 48)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                            )
                            .animation(.easeOut(duration: 0.08), value: beat)
                    }
                }
                HStack(spacing: 12) {
                    Label("Note \(60 + beat)", systemImage: "music.note")
                        .font(.caption.monospaced())
                    Label("CC 1", systemImage: "dial.medium")
                        .font(.caption.monospaced())
                    Label("Bend", systemImage: "arrow.up.and.down")
                        .font(.caption.monospaced())
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption.monospaced())
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Demo: Variable Sensitivity

private struct VariableSensitivityDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // depth oscillates between 0 and 1 over 3 seconds
            let depth = (sin(t / 3 * 2 * .pi) + 1) / 2

            HStack(alignment: .center, spacing: 18) {
                // INPUT side: animated trigger pull (top) and stick depth
                // (bottom). Same depth value drives both so the user sees
                // exactly how analog inputs map to the curve bars beside.
                VStack(spacing: 16) {
                    // Trigger pull
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                                .frame(width: 36, height: 70)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LinearGradient(
                                    colors: [.blue.opacity(0.6), .blue],
                                    startPoint: .top, endPoint: .bottom))
                                .frame(width: 30, height: max(2, CGFloat(depth) * 64))
                                .padding(.bottom, 3)
                        }
                        Text("Trigger")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // Stick deflection (just a circle that slides along Y)
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                                .frame(width: 40, height: 40)
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 12, height: 12)
                                .offset(y: CGFloat(0.5 - depth) * 26)
                        }
                        Text("Stick")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)

                // OUTPUT side: three curve bars showing how the SAME analog
                // depth maps through Linear, Smooth, and Aggressive.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Output mapping")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    curveBar(label: "Linear",     color: .gray,   value: Float(depth))
                    curveBar(label: "Smooth",     color: .blue,   value: SensitivityCurve.exponential.apply(Float(depth)))
                    curveBar(label: "Aggressive", color: .orange, value: SensitivityCurve.aggressive.apply(Float(depth)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
        }
    }

    private func curveBar(label: String, color: Color, value: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: max(0, CGFloat(abs(value))) * proxy.size.width)
                }
            }
            .frame(height: 12)
            Text(String(format: "%.0f%%", abs(value) * 100))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Demo: Deadzone

private struct DeadzoneDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Thumb traces an outward spiral so it crosses both rings.
            let phase = t.truncatingRemainder(dividingBy: 5) / 5
            let radius = phase * 70
            let angle = phase * 4 * .pi
            let x = cos(angle) * radius
            let y = sin(angle) * radius
            let magnitude = radius / 70

            HStack(spacing: 28) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 150, height: 150)
                    // Inner deadzone (red)
                    Circle()
                        .stroke(Color.red.opacity(0.7), lineWidth: 1.5)
                        .frame(width: 30, height: 30)
                    // Outer deadzone (green)
                    Circle()
                        .stroke(Color.green.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 128, height: 128)
                    // Thumb
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                        .offset(x: x, y: y)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Inner: 0.20")
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                    Text("Outer: 0.85")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                    Divider().frame(width: 100)
                    Text("Raw: \(String(format: "%.0f%%", magnitude * 100))")
                        .font(.caption.monospaced())
                    let remapped = max(0, min(1, (magnitude - 0.2) / (0.85 - 0.2)))
                    Text("Output: \(String(format: "%.0f%%", remapped * 100))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

// MARK: - Demo: Macros & Turbo

private struct MacrosDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let cyclePos = t.truncatingRemainder(dividingBy: 2.5)

            let events: [(name: String, at: Double, hold: Double)] = [
                ("Cmd",  0.0, 0.6),
                ("C",    0.15, 0.10),
                ("Tab",  0.6, 0.10),
                ("Cmd",  0.9, 0.6),
                ("V",    1.05, 0.10),
            ]

            VStack(alignment: .leading, spacing: 12) {
                Text("Macro: Copy → Switch → Paste")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        // Timeline bar
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 32)
                        // Each event as a coloured block
                        ForEach(0..<events.count, id: \.self) { i in
                            let e = events[i]
                            RoundedRectangle(cornerRadius: 3)
                                .fill(cyclePos >= e.at && cyclePos < e.at + e.hold
                                      ? Color.yellow : Color.yellow.opacity(0.35))
                                .frame(width: CGFloat(e.hold / 2.5) * proxy.size.width,
                                       height: 32)
                                .offset(x: CGFloat(e.at / 2.5) * proxy.size.width)
                                .overlay(
                                    Text(e.name)
                                        .font(.caption2.monospaced())
                                        .offset(x: CGFloat(e.at / 2.5) * proxy.size.width + 4, y: 0),
                                    alignment: .topLeading
                                )
                        }
                        // Playhead
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 2, height: 32)
                            .offset(x: CGFloat(cyclePos / 2.5) * proxy.size.width)
                    }
                }
                .frame(height: 32)
                Text("Turbo: spacebar at 12 Hz while held")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<24, id: \.self) { i in
                        let on = (Int(t * 12) + i) % 2 == 0
                        Rectangle()
                            .fill(on ? Color.yellow : Color.yellow.opacity(0.2))
                            .frame(width: 8, height: 12)
                    }
                }
            }
            .padding(.horizontal, 18)
        }
    }
}

// MARK: - Demo: Haptic Feedback

private struct HapticDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Press cycle: 0.0 idle, 0.5 pressed, ~1.2s burst, then ease out
            let cycle = t.truncatingRemainder(dividingBy: 2.4)
            let pressed = cycle > 0.4 && cycle < 1.6
            let burst = pressed ? min(1.0, (cycle - 0.4) / 0.15) * max(0, 1.0 - (cycle - 1.4) / 0.2) : 0
            let pulse = pressed ? (sin((cycle - 0.4) * 18) + 1) / 2 : 0

            HStack(spacing: 14) {
                // Input: a button visibly being pressed.
                inputBlock(label: "Press", pressed: pressed, tint: .purple)

                // Gradient arrow charging from input → output.
                gradientArrow(active: pressed, tint: .purple)

                // Output: vibrating controller with intensity bars.
                VStack(spacing: 8) {
                    ZStack {
                        ControllerGlyph(height: 38)
                            .foregroundStyle(.purple.opacity(0.85))
                            .offset(x: CGFloat(sin(t * 40)) * burst * 2,
                                    y: CGFloat(cos(t * 40)) * burst * 2)
                        if pressed {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.title2)
                                .foregroundStyle(.purple.opacity(0.6 + burst * 0.4))
                                .offset(y: -38)
                        }
                    }
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(0..<18, id: \.self) { i in
                            let lane = Double(i) / 18
                            let h = (sin((lane + t * 1.5) * 2 * .pi) + 1) / 2
                            let height = max(4, CGFloat(h) * CGFloat(pulse) * 36)
                            Capsule()
                                .fill(Color.purple.opacity(0.85))
                                .frame(width: 3, height: height)
                        }
                    }
                    .frame(height: 38)
                    Text(pressed ? "Vibrating" : "Idle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 140)
            }
        }
    }
}

// MARK: - Demo: Spoken Feedback

private struct SpeechDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // A new phrase fires every 1.5s; "pressed" window lines up with
            // the first 0.5s of each phrase so the arrow visibly flashes
            // before the speech bubble appears.
            let cycle = t.truncatingRemainder(dividingBy: 6)
            let phraseIndex = Int(cycle / 1.5)
            let phrase = ["Reload", "Ready", "Cover me", "Push forward"][phraseIndex]
            let withinPhrase = cycle.truncatingRemainder(dividingBy: 1.5)
            let pressed = withinPhrase < 0.5

            HStack(spacing: 14) {
                // Input: button press.
                inputBlock(label: "Press", pressed: pressed, tint: .indigo)

                // Gradient arrow.
                gradientArrow(active: pressed, tint: .indigo)

                // Output: speaker + speech bubble + waveform.
                VStack(spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.title2)
                            .iconTint(.indigo)
                        Text("“\(phrase)”")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.indigo.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.indigo.opacity(0.35),
                                            lineWidth: 0.5)
                            )
                            .id(phrase)
                            .transition(.scale.combined(with: .opacity))
                            .animation(.easeInOut(duration: 0.35), value: phrase)
                    }
                    HStack(spacing: 3) {
                        ForEach(0..<20, id: \.self) { i in
                            let phase = (Double(i) / 20 + t * 2)
                                .truncatingRemainder(dividingBy: 1)
                            let h = (sin(phase * 2 * .pi) + 1) / 2
                            Capsule()
                                .fill(Color.indigo.opacity(0.7))
                                .frame(width: 3, height: max(4, CGFloat(h) * 30))
                        }
                    }
                    .frame(height: 32)
                }
                .frame(width: 200)
            }
        }
    }
}

// MARK: - Demo: Light Bar

private struct LightBarDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let hue = t.truncatingRemainder(dividingBy: 6) / 6
            let color = Color(hue: hue, saturation: 0.85, brightness: 1)

            HStack(spacing: 24) {
                // DualSense silhouette with the light bar drawn ABOVE it
                // (offset further up so the colour swatch doesn't visually
                // clash with the controller's own shape).
                VStack(spacing: 14) {
                    ZStack {
                        Capsule()
                            .fill(color)
                            .frame(width: 80, height: 12)
                            .blur(radius: 8)
                        Capsule()
                            .fill(color)
                            .frame(width: 60, height: 6)
                    }
                    ControllerGlyph(height: 70)
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                // Hue ring
                ZStack {
                    ForEach(0..<24, id: \.self) { i in
                        let h = Double(i) / 24
                        Rectangle()
                            .fill(Color(hue: h, saturation: 0.85, brightness: 1))
                            .frame(width: 6, height: 18)
                            .offset(y: -50)
                            .rotationEffect(.degrees(Double(i) * 15))
                    }
                    Circle()
                        .stroke(color, lineWidth: 2)
                        .frame(width: 80, height: 80)
                }
            }
        }
    }
}

// MARK: - Demo: Wide Controller Support

private struct ControllersDemo: View {
    private let entries: [(symbol: String, name: String)] = [
        ("gamecontroller.fill", "DualSense"),
        ("gamecontroller.fill", "Xbox"),
        ("gamecontroller.fill", "Switch Pro"),
        ("gamecontroller.fill", "8BitDo Pro 2"),
        ("gamecontroller.fill", "Stadia"),
        ("gamecontroller.fill", "DualShock 4"),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let active = Int(t.truncatingRemainder(dividingBy: Double(entries.count) * 1.0))

            VStack(spacing: 12) {
                HStack(spacing: 18) {
                    ForEach(0..<entries.count, id: \.self) { i in
                        let isActive = i == active
                        VStack(spacing: 6) {
                            IconView(name: entries[i].symbol, glyphHeight: isActive ? 24 : 17)
                                .font(.system(size: isActive ? 30 : 22))
                                .foregroundStyle(isActive ? Color.cyan : Color.secondary.opacity(0.6))
                            Text(entries[i].name)
                                .font(.caption2)
                                .foregroundStyle(isActive ? .primary : .secondary)
                        }
                        .animation(.easeInOut(duration: 0.3), value: isActive)
                    }
                }
                Text("...plus any MFi gamepad")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Demo: Gyroscope Motion

private struct GyroDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Yaw oscillates left/right; pitch traces a slower curve; roll
            // adds a third axis of motion so the 3D model shows off all
            // three rotations. Each phase has a different period so the
            // demo never repeats a static-looking instant.
            let yaw   = Float(sin(t / 3.5 * 2 * .pi))   // -1...1
            let pitch = Float(sin(t / 2.2 * 2 * .pi))   // -1...1
            let roll  = Float(sin(t / 4.1 * 2 * .pi))   // -1...1

            // Cursor mirror on the right: lags slightly so it looks like
            // the controller is "driving" the cursor.
            let cursorX = CGFloat(yaw) * 90
            let cursorY = CGFloat(pitch) * 55

            HStack(spacing: 24) {
                // Shared 3D gyro model. Magnitudes are scaled so the demo
                // looks lively without spinning too aggressively.
                GyroVisualizationView(
                    gyroX: pitch * 1.2,
                    gyroY: yaw * 1.2,
                    gyroZ: roll * 0.8,
                    rollAngle: roll * 0.35,
                    pitchAngle: pitch * 0.35,
                    yawAngle: yaw * 0.45,
                    mode: .large
                )

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)

                // Cursor that mirrors the controller's tilt - the runtime
                // effect when you bind gyro to mouse motion.
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 220, height: 140)
                    // Crosshair grid
                    Path { p in
                        p.move(to: CGPoint(x: 110, y: 0))
                        p.addLine(to: CGPoint(x: 110, y: 140))
                        p.move(to: CGPoint(x: 0, y: 70))
                        p.addLine(to: CGPoint(x: 220, y: 70))
                    }
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)

                    Image(systemName: "cursorarrow.rays")
                        .font(.title2)
                        .iconTint(.teal)
                        .offset(x: cursorX, y: cursorY)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Demo: Touchpad Mouse

private struct TouchpadDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Finger traces a figure-8 across the trackpad.
            let p = t.truncatingRemainder(dividingBy: 3) / 3
            let theta = p * 2 * .pi
            let fingerX = CGFloat(sin(theta)) * 80
            let fingerY = CGFloat(sin(theta * 2)) * 25
            // Cursor mirrors the finger but stays inside the small desktop
            // rect on the right (200×120). A 1:1 X mapping plus a slight Y
            // bump keeps it visibly bounded without clipping.
            let cursorX = fingerX
            let cursorY = fingerY * 1.4

            HStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.mint.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 200, height: 90)
                    // Faint trail
                    ForEach(0..<8, id: \.self) { i in
                        let lag = Double(i) * 0.04
                        let lagTheta = (p - lag) * 2 * .pi
                        let lx = CGFloat(sin(lagTheta)) * 80
                        let ly = CGFloat(sin(lagTheta * 2)) * 25
                        Circle()
                            .fill(Color.mint.opacity(0.15 + 0.05 * Double(8 - i)))
                            .frame(width: 14 - CGFloat(i) * 1.2, height: 14 - CGFloat(i) * 1.2)
                            .offset(x: lx, y: ly)
                    }
                    Circle()
                        .fill(Color.mint)
                        .frame(width: 16, height: 16)
                        .offset(x: fingerX, y: fingerY)
                    Text("Touchpad")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .offset(y: 60)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 200, height: 120)
                    Image(systemName: "cursorarrow.rays")
                        .font(.title2)
                        .iconTint(.mint)
                        .offset(x: cursorX, y: cursorY)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Demo: Lifetime Statistics

private struct StatsDemo: View {
    private let labels = ["Cross", "Square", "L Trig", "R Trig", "Stick", "D-Pad", "Touch"]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 8) / 8
            let presses = Int(125_437 + phase * 4321)
            let keys    = Int( 89_204 + phase * 3102)
            let clicks  = Int( 21_018 + phase * 802)
            let midi    = Int(  6_417 + phase * 92)

            VStack(spacing: 10) {
                // Top-row KPI tiles. Four counters that look like a real stats
                // dashboard rather than a single floating number.
                HStack(spacing: 8) {
                    kpiTile(icon: "hand.tap.fill",        value: presses, label: "Button presses", tint: .brown)
                    kpiTile(icon: "keyboard.fill",        value: keys,    label: "Key outputs",    tint: .orange)
                    kpiTile(icon: "cursorarrow.click.2",  value: clicks,  label: "Mouse clicks",   tint: .blue)
                    kpiTile(icon: "music.note",           value: midi,    label: "MIDI events",    tint: .pink)
                }
                .padding(.horizontal, 16)

                // Bar chart + axis line below for "most-pressed inputs."
                VStack(spacing: 2) {
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                            let lane = Double(i) / Double(labels.count)
                            let local = (t * 0.6 + lane * 1.7).truncatingRemainder(dividingBy: 2 * .pi)
                            let raw = (sin(local) + 1.2) / 2.4
                            let height = max(10, CGFloat(raw) * 64)
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(LinearGradient(
                                        colors: [.brown.opacity(0.45),
                                                 .brown.opacity(0.85)],
                                        startPoint: .top, endPoint: .bottom))
                                    .frame(width: 18, height: height)
                                Text(label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(height: 80)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 0.5)
                }
                .padding(.horizontal, 16)

                // Footer reassurance about privacy.
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                    Text("Stored locally · no telemetry")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func kpiTile(icon: String, value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(value.formatted())
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Demo: Toggle Mode

/// Animates a face button being pressed twice. First press latches the output
/// ON and it stays on while the finger is lifted; second press releases it.
/// The "OUTPUT" lamp on the right shows the latched state, the press indicator
/// pulses only while the button is physically down.
private struct ToggleModeDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        // 4.0s cycle:
        //   0.0-0.4   press #1 (latch ON)
        //   0.4-2.0   button released, output STAYS ON
        //   2.0-2.4   press #2 (release)
        //   2.4-4.0   button released, output OFF
        let cycle = t.truncatingRemainder(dividingBy: 4.0)
        let firstHalf = cycle < 2.0
        let pressing = (cycle < 0.4) || (cycle >= 2.0 && cycle < 2.4)
        let latched = firstHalf

        HStack(spacing: 14) {
            inputBlock(label: "Tap", pressed: pressing, tint: .orange)
            pressCounter(firstHalf: firstHalf)
            gradientArrow(active: pressing, tint: .orange)
            outputLamp(latched: latched)
        }
    }

    @ViewBuilder
    private func pressCounter(firstHalf: Bool) -> some View {
        let pip1Color: Color = firstHalf ? .orange : Color.secondary.opacity(0.3)
        let pip2Color: Color = firstHalf ? Color.secondary.opacity(0.3) : .orange

        VStack(spacing: 4) {
            Text(firstHalf ? "Press 1" : "Press 2")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .id(firstHalf)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: firstHalf)
            HStack(spacing: 4) {
                Circle().fill(pip1Color).frame(width: 8, height: 8)
                Circle().fill(pip2Color).frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private func outputLamp(latched: Bool) -> some View {
        let fillColor: Color = latched ? Color.orange.opacity(0.85) : Color.secondary.opacity(0.18)
        let strokeColor: Color = latched ? .orange : Color.secondary.opacity(0.4)
        let strokeWidth: CGFloat = latched ? 2 : 1
        let textColor: Color = latched ? .white : .secondary
        let labelText = latched ? "HELD" : "OFF"
        let labelColor: Color = latched ? Color.white.opacity(0.8) : Color(NSColor.tertiaryLabelColor)
        let shadowColor: Color = latched ? Color.orange.opacity(0.5) : .clear

        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(fillColor)
                RoundedRectangle(cornerRadius: 10).stroke(strokeColor, lineWidth: strokeWidth)
                VStack(spacing: 2) {
                    Text("W")
                        .font(.system(size: 28, weight: .heavy, design: .monospaced))
                        .foregroundStyle(textColor)
                    Text(labelText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(labelColor)
                }
            }
            .frame(width: 92, height: 92)
            .shadow(color: shadowColor, radius: 12)
            .animation(.easeOut(duration: 0.18), value: latched)

            Text(latched ? "Auto-running" : "Released")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Demo: Stacked Outputs

/// One physical press fans out into four parallel outputs (key + click + MIDI +
/// speech). Each output lights at the same instant; the whole point is to
/// contrast with macros, which sequence outputs in time.
private struct StackedOutputsDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        // 2.4s cycle, press for the first 0.5s.
        let cycle = t.truncatingRemainder(dividingBy: 2.4)
        let pressed = cycle < 0.5
        // All four outputs flash together with the press.
        let flash: Double = pressed
            ? min(1.0, cycle / 0.15)
            : max(0, 1.0 - (cycle - 0.5) / 0.4)

        HStack(spacing: 16) {
            inputBlock(label: "Press", pressed: pressed, tint: .blue)
            fanOutSplitter(flash: flash)
            outputColumn(flash: flash)
        }
    }

    @ViewBuilder
    private func fanOutSplitter(flash: Double) -> some View {
        let strokeOpacity: Double = 0.35 + flash * 0.55

        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 50))
                p.addLine(to: CGPoint(x: 30, y: 50))
                for i in 0..<4 {
                    let y = CGFloat(i) * 28 + 4
                    p.move(to: CGPoint(x: 30, y: 50))
                    p.addLine(to: CGPoint(x: 30, y: y))
                    p.addLine(to: CGPoint(x: 60, y: y))
                }
            }
            .stroke(
                Color.blue.opacity(strokeOpacity),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 60, height: 100)
    }

    @ViewBuilder
    private func outputColumn(flash: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            outputRow(icon: "keyboard",            text: "Key  E",   flash: flash)
            outputRow(icon: "cursorarrow.click.2", text: "Click L",  flash: flash)
            outputRow(icon: "music.note",          text: "MIDI 60",  flash: flash)
            outputRow(icon: "speaker.wave.2.fill", text: "“Reload”", flash: flash)
        }
        .frame(width: 150)
    }

    @ViewBuilder
    private func outputRow(icon: String, text: String, flash: Double) -> some View {
        let lit = flash > 0.05
        let fillColor: Color = lit
            ? Color.blue.opacity(0.25 + flash * 0.45)
            : Color.secondary.opacity(0.12)
        let strokeColor: Color = lit ? .blue : Color.secondary.opacity(0.35)
        let strokeWidth: CGFloat = lit ? 1.5 : 0.5
        let iconColor: Color = lit ? .blue : .secondary
        let textColor: Color = lit ? .primary : .secondary

        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(fillColor)
                RoundedRectangle(cornerRadius: 6).stroke(strokeColor, lineWidth: strokeWidth)
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 28, height: 24)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(textColor)
        }
    }
}

// MARK: - Demo: Auto-Launch + Cursor Confine

/// A preset card activates, an app icon swings in (auto-launch), and a glowing
/// confine ring appears around the cursor area. Cursor wanders but gets gently
/// nudged back when it touches the edge.
private struct AutoLaunchDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 4.0)
        let activated = cycle > 0.2
        let pulse = (sin(t * 3) + 1) / 2
        let cursorX = CGFloat(sin(t * 1.6)) * 70
        let cursorY = CGFloat(cos(t * 1.1)) * 36

        HStack(spacing: 20) {
            activateTile(activated: activated)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            appIcon(activated: activated)
            confineArea(pulse: pulse, cursorX: cursorX, cursorY: cursorY)
        }
    }

    @ViewBuilder
    private func activateTile(activated: Bool) -> some View {
        let strokeOpacity: Double = activated ? 0.9 : 0.4
        let strokeWidth: CGFloat = activated ? 2 : 1
        let shadowColor: Color = activated ? Color.green.opacity(0.5) : .clear

        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.18))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.green.opacity(strokeOpacity), lineWidth: strokeWidth)
                VStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.title2)
                        .iconTint(.green)
                    Text("Activate")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 70, height: 70)
            .shadow(color: shadowColor, radius: 10)
            Text("Preset")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func appIcon(activated: Bool) -> some View {
        let yOffset: CGFloat = activated ? 0 : 14
        let opacity: Double = activated ? 1 : 0

        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(
                        colors: [Color.green.opacity(0.6), .green],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                Image(systemName: "app.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .offset(y: yOffset)
            .opacity(opacity)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: activated)
            Text("App launched")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func confineArea(pulse: Double, cursorX: CGFloat, cursorY: CGFloat) -> some View {
        let strokeOpacity: Double = 0.4 + pulse * 0.4

        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(strokeOpacity),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: 170, height: 100)
            Image(systemName: "cursorarrow")
                .font(.title3)
                .iconTint(.green)
                .offset(x: cursorX, y: cursorY)
            Text("Confine")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: 64)
        }
    }
}

// MARK: - Demo: MIDI CC Dials

/// A stick rotates around its circle and four CC channels emit continuous
/// values that follow the stick's X / Y / radius / angle. Shown as labeled
/// horizontal bars so it reads as "soft knobs for your DAW."
private struct MidiCCDemo: View {
    var body: some View {
        TimelineView(.animation) { context in
            content(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    @ViewBuilder
    private func content(at t: TimeInterval) -> some View {
        let angle = t.truncatingRemainder(dividingBy: 4) / 4 * 2 * .pi
        let radiusFrac = 0.4 + (sin(t / 1.7) + 1) / 4
        let stickRadius: CGFloat = 32
        let thumbX = cos(angle) * stickRadius * radiusFrac
        let thumbY = sin(angle) * stickRadius * radiusFrac

        let ccX     = (cos(angle) * radiusFrac + 1) / 2
        let ccY     = (sin(angle) * radiusFrac + 1) / 2
        let ccR     = radiusFrac
        let ccAngle = (angle / (2 * .pi)).truncatingRemainder(dividingBy: 1)

        HStack(spacing: 22) {
            stickColumn(t: t, angle: angle, thumbX: thumbX, thumbY: thumbY,
                        stickRadius: stickRadius)
            ccColumn(ccX: ccX, ccY: ccY, ccR: ccR, ccAngle: ccAngle)
        }
    }

    @ViewBuilder
    private func stickColumn(t: TimeInterval, angle: Double,
                             thumbX: Double, thumbY: Double,
                             stickRadius: CGFloat) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 86, height: 86)
                ForEach(0..<10, id: \.self) { i in
                    trailDot(index: i, t: t, angle: angle, stickRadius: stickRadius)
                }
                Circle()
                    .fill(Color.purple)
                    .frame(width: 14, height: 14)
                    .offset(x: thumbX, y: thumbY)
            }
            Text("Right Stick")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trailDot(index i: Int, t: TimeInterval, angle: Double,
                          stickRadius: CGFloat) -> some View {
        let lag = Double(i) * 0.06
        let lagAngle = angle - lag
        let lr = 0.4 + (sin((t - lag) / 1.7) + 1) / 4
        let dotOpacity = max(0, 0.35 - Double(i) * 0.03)

        Circle()
            .fill(Color.purple.opacity(dotOpacity))
            .frame(width: 8, height: 8)
            .offset(x: cos(lagAngle) * stickRadius * lr,
                    y: sin(lagAngle) * stickRadius * lr)
    }

    @ViewBuilder
    private func ccColumn(ccX: Double, ccY: Double, ccR: Double, ccAngle: Double) -> some View {
        VStack(spacing: 6) {
            ccBar(label: "CC 1",  hint: "Mod",     value: ccY)
            ccBar(label: "CC 7",  hint: "Volume",  value: ccR)
            ccBar(label: "CC 10", hint: "Pan",     value: ccAngle)
            ccBar(label: "CC 11", hint: "Express", value: ccX)
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private func ccBar(label: String, hint: String, value: Double) -> some View {
        let v127 = Int(value * 127)
        let fillWidthFrac: CGFloat = max(0, CGFloat(value))

        HStack(spacing: 8) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.purple)
                .frame(width: 42, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.purple.opacity(0.6), .purple],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: fillWidthFrac * proxy.size.width)
                }
            }
            .frame(height: 10)
            Text(String(format: "%3d", v127))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
        }
    }
}
