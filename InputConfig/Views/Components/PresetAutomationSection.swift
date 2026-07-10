import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Per-preset automation panel for the preset editor (labelled
/// "Automation & Gaming Utilities" in the UI; the type keeps the PresetAutomation
/// name for file-format compatibility). Houses settings that should ride
/// along with each preset rather than living in global app Settings -
/// because what makes sense for, say, a Counter-Strike preset (confine
/// cursor, hide cursor, auto-launch Steam) is exactly wrong for a
/// desktop-productivity preset.
///
/// Wired into PresetEditorView at the bottom of the binding list.
/// Bound to `preset.automation` so changes flow through the editor's
/// normal save / cancel path.
struct PresetAutomationSection: View {
    @SwiftUI.Binding var automation: PresetAutomation
    @State private var expanded: Bool = false
    @State private var showingAppPicker: Bool = false
    @State private var showingAutoSwitchAppPicker: Bool = false
    @AppStorage(FrontmostAppWatcher.enabledDefaultsKey)
    private var autoSwitchGloballyEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    autoLaunchBlock
                    Divider()
                    autoSwitchBlock
                    Divider()
                    cursorBlock
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Automation & Gaming Utilities")
                            .font(.headline)
                        Text(summaryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
            .spotlightAnchor(SpotlightID.automationPanel)
        }
    }

    /// One-line collapsed summary so the section telegraphs what's on
    /// without making the user expand it.
    private var summaryLine: String {
        var parts: [String] = []
        if !automation.launchAppPath.isEmpty {
            let path = automation.launchAppPath
            let last = (path as NSString).lastPathComponent
            parts.append("launches \(last.isEmpty ? path : last)")
        }
        if let apps = automation.autoActivateBundleIDs, !apps.isEmpty {
            parts.append("auto for \(apps.count) \(apps.count == 1 ? "app" : "apps")")
        }
        if automation.confineCursor { parts.append("confine cursor") }
        if automation.autoRecenterCursor { parts.append("auto-recenter") }
        if automation.hideCursorWhileActive { parts.append("hide cursor") }
        if automation.sensitivityMultiplier != 1.0 {
            parts.append(String(format: "sensitivity ×%.2f", automation.sensitivityMultiplier))
        }
        return parts.isEmpty
            ? "Optional extras: auto-launch an app, confine, recenter, or hide the cursor. Expand to set up."
            : parts.joined(separator: " · ")
    }

    // MARK: - Auto launch

    @ViewBuilder
    private var autoLaunchBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
                Text("Auto-launch when preset activates")
                    .font(.subheadline.weight(.semibold))
            }
            HStack {
                TextField("/Applications/Steam.app or com.valvesoftware.steam",
                          text: $automation.launchAppPath)
                    .textFieldStyle(.roundedBorder)
                Button {
                    showingAppPicker = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Pick an application")
                .accessibilityLabel("Pick an application")
                if !automation.launchAppPath.isEmpty {
                    Button {
                        automation.launchAppPath = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                    .accessibilityLabel("Clear launch app")
                }
            }
            TextField("Optional deep link, e.g. steam://run/730",
                      text: $automation.launchURL)
                .textFieldStyle(.roundedBorder)
            Text("Both fields run on activation. Leave blank to disable. Paths accept .app bundles or any executable; identifiers accept reverse-DNS strings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $showingAppPicker,
                      allowedContentTypes: [UTType.application],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                automation.launchAppPath = url.path
            }
        }
    }

    // MARK: - Auto switch by frontmost app

    @ViewBuilder
    private var autoSwitchBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right.square")
                    .foregroundStyle(.secondary)
                Text("Activate when these apps are in front")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showingAutoSwitchAppPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add an application")
                .accessibilityLabel("Add an application")
            }

            let apps = automation.autoActivateBundleIDs ?? []
            if apps.isEmpty {
                Text("Empty. Add an app and this preset activates by itself whenever that app comes to the front, then steps aside when you leave.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(apps, id: \.self) { bundleID in
                    HStack(spacing: 6) {
                        Image(systemName: "app.badge.checkmark")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(displayName(forBundleID: bundleID))
                            .font(.caption)
                        Text(bundleID)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            var list = automation.autoActivateBundleIDs ?? []
                            list.removeAll { $0 == bundleID }
                            automation.autoActivateBundleIDs = list.isEmpty ? nil : list
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                        .accessibilityLabel("Remove \(displayName(forBundleID: bundleID))")
                    }
                }
            }

            if !autoSwitchGloballyEnabled {
                Toggle(isOn: $autoSwitchGloballyEnabled) {
                    Text("Automatic switching is off globally. Turn it on for these lists to take effect.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .controlSize(.small)
            }
        }
        .fileImporter(isPresented: $showingAutoSwitchAppPicker,
                      allowedContentTypes: [UTType.application],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first,
               let bundleID = Bundle(url: url)?.bundleIdentifier {
                var list = automation.autoActivateBundleIDs ?? []
                if !list.contains(bundleID) {
                    list.append(bundleID)
                    automation.autoActivateBundleIDs = list
                }
            }
        }
    }

    private func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    // MARK: - Cursor controls

    @ViewBuilder
    private var cursorBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.motionlines")
                    .foregroundStyle(.secondary)
                Text("Cursor while active")
                    .font(.subheadline.weight(.semibold))
            }
            Text("These only run while this preset is the active one. Stopping the engine restores the system cursor.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $automation.confineCursor) {
                Label("Confine cursor away from screen edges",
                      systemImage: "rectangle.inset.filled")
            }
            if automation.confineCursor {
                HStack {
                    Text("Buffer:").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $automation.confineBufferPx, in: 1...200, step: 1)
                        .accessibilityLabel("Cursor confine buffer")
                        .accessibilityValue("\(Int(automation.confineBufferPx)) pixels")
                    Text("\(Int(automation.confineBufferPx)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }

            Toggle(isOn: $automation.autoRecenterCursor) {
                Label("Auto-recenter cursor",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            if automation.autoRecenterCursor {
                HStack {
                    Text("Interval:").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $automation.autoRecenterIntervalMs, in: 50...2000, step: 10)
                        .accessibilityLabel("Auto-recenter interval")
                        .accessibilityValue("\(Int(automation.autoRecenterIntervalMs)) milliseconds")
                    Text("\(Int(automation.autoRecenterIntervalMs)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }

            Toggle(isOn: $automation.hideCursorWhileActive) {
                Label("Hide system cursor",
                      systemImage: "cursorarrow.slash")
            }

            HStack {
                Label("Sensitivity multiplier",
                      systemImage: "speedometer")
                Spacer()
                Text(String(format: "×%.2f", automation.sensitivityMultiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $automation.sensitivityMultiplier, in: 0.1...5.0, step: 0.05)
                .accessibilityLabel("Sensitivity multiplier")
                .accessibilityValue(String(format: "times %.2f", automation.sensitivityMultiplier))
        }
    }
}

/// Per-preset configuration for the one-stick driving system (build 18).
/// Bound to `preset.driveConfig` (optional). Toggling it on materializes a
/// default DriveConfig; the form then exposes the stick, steering, throttle,
/// and reverse-gesture settings. Lives in this file so it ships in the
/// existing Xcode target alongside the other per-preset section.
struct DriveModeSection: View {
    @SwiftUI.Binding var driveConfig: DriveConfig?
    @State private var expanded: Bool = false
    @EnvironmentObject private var controllerService: GameControllerService
    @EnvironmentObject private var mappingEngine: MappingEngine

    /// Live axis values for the configured slot, refreshed while the panel is
    /// open so the user can see which axis moves and confirm their mapping.
    @State private var axisValues: [Int: Float] = [:]
    private let axisTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// Test-drive sandbox state: a demo vehicle in a logical arena that obeys
    /// the exact drive parameters configured above, stepped on the same timer.
    private static let arenaSize = CGSize(width: 560, height: 200)
    @State private var carPos = CGPoint(x: 280, y: 100)
    @State private var carHeading: Double = -Double.pi / 2
    @State private var carSpeed: Double = 0
    @State private var lastPhysicsTick: Date?
    @State private var virtualStick: CGSize = .zero
    @State private var trail: [CGPoint] = []

    enum StickChoice: String, CaseIterable, Identifiable {
        case left, right, custom
        var id: String { rawValue }
        var label: String { self == .left ? "Left stick" : self == .right ? "Right stick" : "Custom" }
    }

    /// Non-optional working binding; reads a default when nil.
    private var cfg: SwiftUI.Binding<DriveConfig> {
        SwiftUI.Binding(get: { driveConfig ?? DriveConfig() },
                        set: { driveConfig = $0 })
    }
    private var isOn: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { driveConfig?.enabled ?? false },
            set: { on in
                var c = driveConfig ?? DriveConfig()
                c.enabled = on
                driveConfig = c
            })
    }
    private var stickChoice: SwiftUI.Binding<StickChoice> {
        SwiftUI.Binding(
            get: {
                let s = cfg.wrappedValue
                if s.steerAxis == 0 && s.throttleAxis == 1 { return .left }
                if s.steerAxis == 2 && s.throttleAxis == 3 { return .right }
                return .custom
            },
            set: { choice in
                var c = cfg.wrappedValue
                switch choice {
                case .left:  c.steerAxis = 0; c.throttleAxis = 1
                case .right: c.steerAxis = 2; c.throttleAxis = 3
                case .custom: break
                }
                cfg.wrappedValue = c
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: isOn) {
                        Text("Enable one-stick driving")
                        Text("Steer, accelerate, brake, and shift Drive/Reverse from a single stick. Outputs keyboard and mouse, so it works in games you can drive with the keyboard.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityHint("Turns the whole one-stick driving scheme on or off for this preset.")
                    if driveConfig?.enabled == true {
                        liveFeedback
                        testDriveBlock
                        Divider(); stickBlock
                        Divider(); steeringBlock
                        Divider(); throttleBlock
                        Divider(); reverseBlock
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "steeringwheel").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("One-Stick Driving").font(.headline)
                        Text(driveConfig?.enabled == true ? driveSummary : "Wheelchair-style driving from one joystick")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if driveConfig?.enabled == true {
                        Text("On")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.2)))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
        }
        .onReceive(axisTimer) { _ in
            // CRITICAL: no unconditional @State writes here. This fires 30x/s
            // for as long as the editor is open; a no-op write still marks the
            // view dirty, and in a large editor each re-layout can outlast the
            // tick interval - the main thread never drains and the app hangs.
            guard expanded, driveConfig?.enabled == true else {
                if lastPhysicsTick != nil { lastPhysicsTick = nil }
                return
            }
            let axes = controllerService.readControllerState(at: cfg.wrappedValue.slot)?.axes ?? [:]
            if axes != axisValues { axisValues = axes }
            stepCar()
        }
    }

    // MARK: - Live feedback (while actually driving)
    @ViewBuilder private var liveFeedback: some View {
        if let s = mappingEngine.driveLiveState {
            HStack(spacing: 10) {
                Text(s.reverse ? "REVERSE" : "DRIVE")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill((s.reverse ? Color.orange : Color.green).opacity(0.25)))
                    .foregroundStyle(s.reverse ? .orange : .green)
                miniBar("Power", Double(s.throttle), s.reverse ? .orange : .green)
                miniBar("Brake", Double(s.brake), .red)
                miniBar("Steer", Double(abs(s.steer)), .blue)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live drive state: \(s.reverse ? "reverse" : "drive"), power \(Int(s.throttle * 100)) percent")
        }
    }

    // MARK: - Test drive sandbox

    /// Whether the demo vehicle is currently in reverse: the real processor's
    /// gear when the engine is running, otherwise inferred from motion.
    private var demoReversing: Bool {
        if let s = mappingEngine.driveLiveState { return s.reverse }
        return carSpeed < -2
    }

    /// Live 2D sandbox: a vehicle that obeys the exact parameters configured
    /// below, so deadzone, curve, and coast-brake changes can be felt the
    /// moment they're made. Driven by the real stick (or the true drive
    /// engine when the preset is running); the on-screen virtual stick covers
    /// testing with no controller connected.
    @ViewBuilder private var testDriveBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Test Drive", "car.fill")
            HStack(alignment: .top, spacing: 12) {
                arenaCanvas
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    .accessibilityLabel("Test drive arena")
                    .accessibilityValue(demoReversing ? "Reversing" : "Driving, speed \(Int(min(100, abs(carSpeed) / 1.5))) percent")

                VStack(spacing: 10) {
                    Text(demoReversing ? "REVERSE" : "DRIVE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill((demoReversing ? Color.orange : Color.green).opacity(0.25)))
                        .foregroundStyle(demoReversing ? .orange : .green)

                    VStack(spacing: 2) {
                        Text("\(Int(min(100, abs(carSpeed) / 1.5)))%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                        Text("Speed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    virtualStickPad

                    Button("Reset") {
                        carPos = CGPoint(x: Self.arenaSize.width / 2, y: Self.arenaSize.height / 2)
                        carHeading = -Double.pi / 2
                        carSpeed = 0
                        trail.removeAll()
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .accessibilityHint("Puts the demo vehicle back in the middle of the arena.")
                }
                .frame(width: 92)
            }
            Text("Move your stick to drive the demo vehicle. No controller? Drag the virtual stick. Parameter changes below apply instantly.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var arenaCanvas: some View {
        Canvas { context, size in
            let s = min(size.width / Self.arenaSize.width, size.height / Self.arenaSize.height)
            context.translateBy(x: (size.width - Self.arenaSize.width * s) / 2,
                                y: (size.height - Self.arenaSize.height * s) / 2)
            context.scaleBy(x: s, y: s)

            // Floor grid so motion is visible even mid-arena.
            var grid = Path()
            for x in stride(from: 70.0, to: Self.arenaSize.width, by: 70) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: Self.arenaSize.height))
            }
            for y in stride(from: 50.0, to: Self.arenaSize.height, by: 50) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: Self.arenaSize.width, y: y))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

            // Fading tyre trail.
            if trail.count > 1 {
                var path = Path()
                path.move(to: trail[0])
                for p in trail.dropFirst() { path.addLine(to: p) }
                context.stroke(path, with: .color((demoReversing ? Color.orange : Color.green).opacity(0.3)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // The vehicle: rounded body + windshield, nose along +x.
            var car = context
            car.translateBy(x: carPos.x, y: carPos.y)
            car.rotate(by: Angle(radians: carHeading))
            let bodyColor: Color = demoReversing ? .orange : .accentColor
            car.fill(Path(roundedRect: CGRect(x: -16, y: -9, width: 32, height: 18), cornerRadius: 6),
                     with: .color(bodyColor))
            car.fill(Path(roundedRect: CGRect(x: 3, y: -6, width: 8, height: 12), cornerRadius: 2),
                     with: .color(.white.opacity(0.75)))
        }
    }

    /// Draggable stand-in stick for testing with no controller connected.
    private var virtualStickPad: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.1))
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            Circle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 24, height: 24)
                .offset(x: virtualStick.width * 22, y: virtualStick.height * 22)
        }
        .frame(width: 70, height: 70)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    virtualStick = CGSize(width: max(-1, min(1, g.translation.width / 30)),
                                          height: max(-1, min(1, g.translation.height / 30)))
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                        virtualStick = .zero
                    }
                }
        )
        .accessibilityLabel("Virtual test stick")
        .accessibilityHint("Drag to drive the demo vehicle when no controller is connected.")
    }

    /// One physics tick. Prefers the REAL drive engine's output (when the
    /// preset is running) so the demo matches what a game would receive;
    /// otherwise shapes raw stick input through the same deadzone and curve
    /// parameters the engine uses.
    private func stepCar() {
        let now = Date()
        guard let last = lastPhysicsTick else {
            lastPhysicsTick = now
            return
        }
        let dt = min(now.timeIntervalSince(last), 0.08)
        guard dt > 0 else { return }
        let c = cfg.wrappedValue

        var steer: Double = 0
        var accel: Double = 0   // -1 full reverse ... +1 full power
        var brake: Double = 0
        if let s = mappingEngine.driveLiveState {
            steer = Double(s.steer)
            accel = (s.reverse ? -1 : 1) * Double(s.throttle)
            brake = Double(s.brake)
        } else {
            var x = Double(axisValues[c.steerAxis] ?? 0)
            var fwd: Double
            if c.throttleIsTrigger {
                fwd = (Double(axisValues[c.throttleAxis] ?? -1) + 1) / 2
            } else {
                fwd = -Double(axisValues[c.throttleAxis] ?? 0)
            }
            if c.invertSteer { x = -x }
            if c.invertThrottle { fwd = -fwd }
            // Fall back to the on-screen stick when the controller is idle.
            if abs(x) < 0.04 && abs(fwd) < 0.04 {
                x = Double(virtualStick.width)
                fwd = -Double(virtualStick.height)
            }
            steer = shapedAxis(x, deadzone: c.deadzone, curve: c.steerCurve)
            accel = shapedAxis(fwd, deadzone: c.deadzone, curve: c.throttleCurve)
        }

        // Fully idle (no command, car at rest, trail drained): skip every
        // write so an open-but-untouched panel does zero re-render work.
        // The dt clamp above absorbs the stale tick stamp when motion resumes.
        if steer == 0 && accel == 0 && brake == 0 && carSpeed == 0 && trail.isEmpty {
            return
        }
        lastPhysicsTick = now

        // Speed: ease toward the commanded speed. Coast-brake makes the
        // centered-stick stop noticeably firmer, like a power wheelchair.
        let maxForward = 150.0, maxReverse = 70.0
        let target = accel >= 0 ? accel * maxForward : accel * maxReverse
        let centered = abs(accel) < 0.02
        var rate = centered ? (c.coastBrake ? 2.0 + 3.0 * c.coastBrakeStrength : 0.7) : 2.4
        if brake > 0.02 { rate += 4.0 * brake }
        carSpeed += ((brake > 0.5 ? 0 : target) - carSpeed) * min(1, rate * dt)
        if centered && abs(carSpeed) < 0.5 { carSpeed = 0 }

        // Heading: turn rate scales with speed so it steers like a vehicle,
        // and flips while reversing, like a real car.
        let speedFrac = max(-1, min(1, carSpeed / maxForward * 3))
        carHeading += steer * 3.2 * speedFrac * dt

        var p = carPos
        p.x += CGFloat(cos(carHeading) * carSpeed * dt)
        p.y += CGFloat(sin(carHeading) * carSpeed * dt)
        let margin: CGFloat = 18
        if p.x < margin { p.x = margin; carSpeed *= -0.25 }
        if p.x > Self.arenaSize.width - margin { p.x = Self.arenaSize.width - margin; carSpeed *= -0.25 }
        if p.y < margin { p.y = margin; carSpeed *= -0.25 }
        if p.y > Self.arenaSize.height - margin { p.y = Self.arenaSize.height - margin; carSpeed *= -0.25 }
        carPos = p

        if abs(carSpeed) > 2 {
            trail.append(p)
            if trail.count > 90 { trail.removeFirst(trail.count - 90) }
        } else if !trail.isEmpty && carSpeed == 0 {
            // Let the trail fade out once stopped.
            trail.removeFirst()
        }
    }

    /// Deadzone + response-curve shaping, matching the engine's semantics:
    /// remap past the deadzone to 0-1, then apply the curve exponent.
    private func shapedAxis(_ v: Double, deadzone: Double, curve: Double) -> Double {
        let a = abs(v)
        guard a > deadzone, deadzone < 1 else { return 0 }
        let n = min(1, (a - deadzone) / (1 - deadzone))
        return (v < 0 ? -1 : 1) * pow(n, max(0.1, curve))
    }

    // MARK: - Stick
    private var stickBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Stick", "gamecontroller")
            Picker("Which stick drives", selection: stickChoice) {
                ForEach(StickChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).controlSize(.small)
            .accessibilityLabel("Which stick drives")
            Stepper("Controller slot: \(cfg.wrappedValue.slot + 1)", value: cfg.slot, in: 0...3)
                .controlSize(.small)
            if stickChoice.wrappedValue == .custom {
                Stepper("Steer axis: \(cfg.wrappedValue.steerAxis)", value: cfg.steerAxis, in: 0...11)
                    .controlSize(.small)
                Stepper("Throttle axis: \(cfg.wrappedValue.throttleAxis)", value: cfg.throttleAxis, in: 0...11)
                    .controlSize(.small)
            }
            // Live readout so the user can confirm which axis is which.
            axisReadout("Steer axis \(cfg.wrappedValue.steerAxis)", cfg.wrappedValue.steerAxis)
            axisReadout("Throttle axis \(cfg.wrappedValue.throttleAxis)", cfg.wrappedValue.throttleAxis)
            HStack(spacing: 8) {
                Button("Set steering to most-moved axis") { if let m = mostDeflected() { cfg.wrappedValue.steerAxis = m } }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(mostDeflected() == nil)
                    .accessibilityHint("Push and hold the stick in one direction first. Disabled until the stick is moved far enough.")
                Button("Set throttle to most-moved axis") { if let m = mostDeflected() { cfg.wrappedValue.throttleAxis = m } }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(mostDeflected() == nil)
                    .accessibilityHint("Push and hold the stick in one direction first. Disabled until the stick is moved far enough.")
            }
            .controlSize(.small).font(.caption)
            Text("Move the stick and watch the bars; or hold it in one direction and tap the matching button.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Invert steering", isOn: cfg.invertSteer).controlSize(.small)
            Toggle("Invert throttle (if pushing up goes backward)", isOn: cfg.invertThrottle).controlSize(.small)
            sliderRow("Deadzone", cfg.deadzone, 0, 0.4, "%.0f%%", 100, "Center deadzone")
        }
    }

    // MARK: - Steering
    private var steeringBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Steering", "arrow.left.and.right")
            Picker("Steering output", selection: cfg.steerMode) {
                ForEach(DriveConfig.SteerMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).controlSize(.small)
            .accessibilityLabel("Steering output")
            if cfg.wrappedValue.steerMode == .mouse {
                sliderRow("Steering speed", cfg.steerMouseSpeed, 4, 40, "%.0f px", 1, "Steering speed")
            } else {
                HStack {
                    Text("Left key").font(.caption)
                    KeyCodePicker(selectedCode: cfg.steerLeftKey).accessibilityLabel("Steer left key")
                    Spacer()
                    Text("Right key").font(.caption)
                    KeyCodePicker(selectedCode: cfg.steerRightKey).accessibilityLabel("Steer right key")
                }
            }
            sliderRow("Steering curve", cfg.steerCurve, 1, 3, "%.1fx", 1, "Steering response curve")
            Text("A higher steering curve gives a gentle center and progressive lock toward full.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Throttle
    private var throttleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Throttle and brake", "gauge.with.dots.needle.67percent")
            HStack {
                Text("Accelerate").font(.caption)
                KeyCodePicker(selectedCode: cfg.accelKey).accessibilityLabel("Accelerate key")
                Spacer()
                Text("Brake").font(.caption)
                KeyCodePicker(selectedCode: cfg.brakeKey).accessibilityLabel("Brake key")
            }
            Toggle("Throttle axis is a trigger (rests at one end)", isOn: cfg.throttleIsTrigger)
                .controlSize(.small)
                .accessibilityHint("Turn on if you assigned an analog trigger instead of a centered stick. Disables the reverse gesture.")
            Toggle("Brake when centered (active slow-down)", isOn: cfg.coastBrake)
                .controlSize(.small)
                .accessibilityHint("Hold a light brake while the stick is centered so the vehicle slows down instead of coasting.")
            if cfg.wrappedValue.coastBrake {
                sliderRow("Slow-down strength", cfg.coastBrakeStrength, 0.1, 1, "%.0f%%", 100, "Active slow-down strength")
            }
            sliderRow("Sensitivity curve", cfg.throttleCurve, 1, 3, "%.1fx", 1, "Throttle sensitivity curve")
            Text("A higher curve gives finer low-speed control.")
                .font(.caption2).foregroundStyle(.secondary)
            sliderRow("Pulse smoothing", SwiftUI.Binding(
                get: { Double(cfg.wrappedValue.pwmPeriodTicks) },
                set: { cfg.wrappedValue.pwmPeriodTicks = Int($0) }), 3, 12, "%.0f", 1, "Pulse smoothing")
            Text("Variable speed is produced by pulsing the key on and off; this sets how smooth that pulsing is.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Reverse gesture
    private var reverseBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Reverse gesture", "arrow.uturn.backward")
            if cfg.wrappedValue.throttleIsTrigger {
                Text("Unavailable while the throttle axis is a trigger (a trigger has no backward pull).")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Toggle("Snap fully back a few times to shift into Reverse", isOn: cfg.reverseGestureEnabled)
                    .controlSize(.small)
                if cfg.wrappedValue.reverseGestureEnabled {
                    Stepper("Back taps to engage: \(cfg.wrappedValue.reverseTapCount)", value: cfg.reverseTapCount, in: 2...4)
                        .controlSize(.small)
                    sliderRow("Within window", SwiftUI.Binding(
                        get: { Double(cfg.wrappedValue.reverseWindowMs) },
                        set: { cfg.wrappedValue.reverseWindowMs = Int($0) }), 300, 1500, "%.0f ms", 1, "Tap window")
                    sliderRow("Back-wall threshold", cfg.gestureThreshold, 0.6, 0.98, "%.0f%%", 100, "Back wall threshold")
                    Text("How far back counts as a wall hit; higher means you must snap nearly all the way.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Text("Reverse key").font(.caption)
                        KeyCodePicker(selectedCode: cfg.reverseKey).accessibilityLabel("Reverse key")
                        Spacer()
                    }
                    Text("Push fully forward to return to Drive.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One-line summary shown in the collapsed header when drive is enabled.
    private var driveSummary: String {
        let c = cfg.wrappedValue
        let stick = stickChoice.wrappedValue.label
        let steer = c.steerMode == .mouse ? "mouse steering" : "key steering"
        let rev = (c.reverseGestureEnabled && !c.throttleIsTrigger) ? ", reverse gesture" : ""
        return "On: \(stick), \(steer)\(rev)"
    }

    // MARK: - Reusable bits
    private func mostDeflected() -> Int? {
        guard let m = axisValues.max(by: { abs($0.value) < abs($1.value) }), abs(m.value) > 0.3 else { return nil }
        return m.key
    }
    private func axisReadout(_ label: String, _ index: Int) -> some View {
        let v = axisValues[index] ?? 0
        return HStack(spacing: 8) {
            Text(label).font(.caption2).frame(width: 116, alignment: .leading)
            ProgressView(value: Double(min(abs(v), 1)))
                .frame(width: 84)
            Text(String(format: "%+.2f", v))
                .font(.caption2.monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) value \(String(format: "%.2f", v))")
    }
    private func miniBar(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 1) {
            ProgressView(value: min(max(value, 0), 1)).tint(color).frame(width: 56)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
    private func blockTitle(_ t: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            IconView(name: symbol, glyphHeight: 9).font(.caption2).foregroundStyle(.tertiary)
            Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }
    private func sliderRow(_ label: String, _ value: SwiftUI.Binding<Double>,
                           _ lo: Double, _ hi: Double, _ fmt: String, _ scale: Double,
                           _ a11y: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 120, alignment: .leading)
            Slider(value: value, in: lo...hi).controlSize(.small)
                .accessibilityLabel(a11y)
                .accessibilityValue(String(format: fmt, value.wrappedValue * scale))
            Text(String(format: fmt, value.wrappedValue * scale))
                .font(.caption2.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }
}
