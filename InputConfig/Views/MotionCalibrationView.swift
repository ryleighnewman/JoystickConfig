import SwiftUI
import GameController

/// Walks the user through calibrating motion (gyro + accelerometer) for a
/// specific controller. The flow:
///
///   1. Pick which connected controller to calibrate.
///   2. Place the controller on a flat surface, face up, perfectly still.
///   3. Tap Start. We average the gyro + accel for ~2 seconds and save
///      that as the controller's "zero" so the mapping engine can subtract
///      it from every incoming sample.
///
/// Once calibrated, presets that bind motion inputs use the corrected
/// values automatically. Calibrations are per-controller-identity and
/// persisted to Application Support, so users only do this once per
/// device.
struct MotionCalibrationView: View {
    @EnvironmentObject var controllerService: GameControllerService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKey: String?
    @State private var captureInProgress: Bool = false
    @State private var captureRemaining: Double = 0
    @State private var captureSamples: [SampleVector] = []
    @State private var lastSavedKey: String?
    /// Two-step calibration flow: first click reveals instructions
    /// (scrolls them into view), second click actually starts the
    /// capture. Prevents accidental calibration with the controller
    /// in a weird orientation.
    @State private var awaitingConfirmation: Bool = false
    /// Integrated orientation in radians, ticked at 30 Hz from the
    /// controller's gyro rates. Used to drive the 3D gyro model when the
    /// controller doesn't expose absolute attitude, so the model HOLDS
    /// its orientation after motion stops instead of snapping to neutral.
    @State private var integratedRoll: Float = 0
    @State private var integratedPitch: Float = 0
    @State private var integratedYaw: Float = 0
    /// The active capture timer, retained so it can be invalidated if the view
    /// is dismissed mid-capture (otherwise it kept ticking and persisted an
    /// abandoned calibration).
    @State private var captureTimer: Timer?

    private struct SampleVector {
        var gx: Float; var gy: Float; var gz: Float
        var ax: Float; var ay: Float; var az: Float
    }

    private let captureDuration: Double = 2.5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header pinned at top; body scrolls underneath so the sheet
            // fits even inside the editor sheet on smaller screens.
            VStack(alignment: .leading, spacing: 14) {
                header
                controllerPicker
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        liveReadings
                            .id("live")

                        Divider()

                        instructions
                            .id("instructions")

                        captureSurface
                            .id("capture")
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
                }
                .onChange(of: awaitingConfirmation) { _, newValue in
                    // Click 1 -> scroll the How-to instructions into view
                    // so the user sees them before confirming.
                    if newValue {
                        withAnimation(.easeOut(duration: 0.35)) {
                            proxy.scrollTo("instructions", anchor: .top)
                        }
                    }
                }
                .onChange(of: captureInProgress) { _, newValue in
                    // Click 2 -> capture started; scroll back to the live
                    // readings so the user can watch the gyro/accel bars
                    // hold steady while the controller stays flat.
                    if newValue {
                        withAnimation(.easeOut(duration: 0.35)) {
                            proxy.scrollTo("live", anchor: .top)
                        }
                    }
                }
            }

            Divider()

            footerButtons
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .frame(width: 560, height: 560)
        // Tick the integrated orientation at 30 Hz from the currently
        // selected controller's gyro rates so the 3D model HOLDS its
        // pose when the controller is still. Paused during capture so
        // the model stays at flat for the duration of calibration.
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            guard !captureInProgress,
                  let entry = selectedControllerEntry,
                  let motion = entry.controller.motion,
                  motion.hasRotationRate else { return }
            let dt: Float = 1.0 / 30.0
            // Use drift-corrected rates so a resting controller's gyro bias
            // doesn't ramp the model to the +/-90 degree clamp, and apply a
            // small per-tick leak toward zero so any residual bias decays
            // instead of accumulating.
            let key = MotionCalibrationService.identityKey(for: entry.controller)
            let (gx, gy, gz) = MotionCalibrationService.shared.correctedGyro(
                x: Float(motion.rotationRate.x),
                y: Float(motion.rotationRate.y),
                z: Float(motion.rotationRate.z),
                forKey: key)
            integratedPitch = (integratedPitch + gx * dt) * 0.98
            integratedYaw   = (integratedYaw + gy * dt) * 0.98
            integratedRoll  = (integratedRoll + gz * dt) * 0.98
            integratedPitch = max(-(.pi / 2), min(.pi / 2, integratedPitch))
            integratedYaw   = max(-(.pi / 2), min(.pi / 2, integratedYaw))
            integratedRoll  = max(-(.pi / 2), min(.pi / 2, integratedRoll))
        }
        // Reset the integrated orientation whenever the user picks a
        // different controller so the model starts from neutral on the
        // new device.
        .onChange(of: selectedKey) { _, _ in
            integratedPitch = 0
            integratedYaw = 0
            integratedRoll = 0
        }
    }

    // MARK: - Selected controller

    /// Tuple for the controller currently selected in the picker. Drives the
    /// live readings panel and the start-capture flow.
    private var selectedControllerEntry: (slot: Int, controller: GCController, info: ControllerInfo)? {
        guard let key = selectedKey else { return nil }
        return motionCapableControllers.first(where: {
            MotionCalibrationService.identityKey(for: $0.controller) == key
        })
    }

    // MARK: - Live readings (diagnostic)

    /// Live numeric + bar readout of the controller's gyro + accelerometer.
    /// Lets the user verify motion is actually flowing BEFORE running
    /// calibration. If a gyro never moves the values here, the controller
    /// either doesn't expose motion or macOS isn't piping it through.
    @ViewBuilder
    private var liveReadings: some View {
        if let entry = selectedControllerEntry, let motion = entry.controller.motion {
            TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(.teal)
                        Text("Live sensor readings")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        availabilityBadge(label: "active",
                                          available: motion.sensorsActive)
                        availabilityBadge(label: "gyro",
                                          available: motion.hasRotationRate)
                        availabilityBadge(label: "gravity",
                                          available: motion.hasGravityAndUserAcceleration)
                    }

                    // 3D gyro model: artificial horizon ring with a tilting
                    // controller silhouette. When the controller exposes
                    // hasAttitude we use the real Euler angles; otherwise
                    // we fall back to scaled gyro RATE values so the model
                    // still visibly tilts when the user rotates the
                    // controller (the rate-only fallback returns to neutral
                    // when motion stops, which is fine for verifying that
                    // input is reaching the app).
                    HStack(spacing: 14) {
                        let gx = motion.hasRotationRate ? Float(motion.rotationRate.x) : 0
                        let gy = motion.hasRotationRate ? Float(motion.rotationRate.y) : 0
                        let gz = motion.hasRotationRate ? Float(motion.rotationRate.z) : 0
                        let attitude = motion.hasAttitude ? attitudeEuler(motion: motion) : nil
                        // GCMotion convention: gyroX = pitch rate, gyroY =
                        // yaw rate, gyroZ = roll rate. Use the integrated
                        // orientation as a fallback when attitude isn't
                        // available, so the model HOLDS its position when
                        // the user puts the controller down instead of
                        // snapping back to neutral.
                        GyroVisualizationView(
                            gyroX: gx,
                            gyroY: gy,
                            gyroZ: gz,
                            rollAngle: attitude?.roll ?? integratedRoll,
                            pitchAngle: attitude?.pitch ?? integratedPitch,
                            yawAngle: attitude?.yaw ?? integratedYaw,
                            mode: .regular
                        )
                        Spacer()
                    }
                    .padding(.vertical, 4)

                    // If sensors require manual activation and aren't active,
                    // try once more. Apple sometimes drops sensorsActive when
                    // a controller re-pairs.
                    if motion.sensorsRequireManualActivation && !motion.sensorsActive {
                        Button {
                            motion.sensorsActive = true
                        } label: {
                            Label("Activate motion sensors", systemImage: "bolt.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.solidCompact)
                    }

                    if motion.hasRotationRate {
                        sensorRow(label: "Gyro",
                                  values: (Float(motion.rotationRate.x),
                                           Float(motion.rotationRate.y),
                                           Float(motion.rotationRate.z)),
                                  scale: 5.0,
                                  unit: "rad/s",
                                  color: .teal)
                    } else {
                        Text("Gyroscope is not reporting. Try a wired connection, or re-pair the controller. Some Bluetooth pairings drop motion data.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Total acceleration (gravity + user motion). Even when
                    // the controller is at rest this should read ~1 g in
                    // whichever axis is pointing down. If THIS reads zero,
                    // the accelerometer hardware isn't reporting at all.
                    sensorRow(label: "Accel (total)",
                              values: (Float(motion.acceleration.x),
                                       Float(motion.acceleration.y),
                                       Float(motion.acceleration.z)),
                              scale: 2.0,
                              unit: "g",
                              color: .blue)

                    // Gravity vector alone. Apple separates gravity from
                    // user motion only when `hasGravityAndUserAcceleration`
                    // is true.
                    if motion.hasGravityAndUserAcceleration {
                        sensorRow(label: "Gravity",
                                  values: (Float(motion.gravity.x),
                                           Float(motion.gravity.y),
                                           Float(motion.gravity.z)),
                                  scale: 1.2,
                                  unit: "g",
                                  color: .purple)

                        sensorRow(label: "User accel",
                                  values: (Float(motion.userAcceleration.x),
                                           Float(motion.userAcceleration.y),
                                           Float(motion.userAcceleration.z)),
                                  scale: 1.5,
                                  unit: "g",
                                  color: .orange)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("How to read this:")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("• At rest, Accel (total) should show ~1.0 g in one axis (the direction of gravity). User accel should be near 0.")
                        Text("• Rotate the controller and watch the Gyro bars move. Shake it to see User accel respond.")
                        Text("• If everything reads exactly 0, motion isn't being delivered. Try wired USB or re-pair Bluetooth.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
            }
        }
    }

    /// Convert the controller's quaternion attitude into Euler roll / pitch
    /// / yaw in radians. Same math as `GameControllerService.readControllerState`
    /// but inline here so the calibration view can drive the gyro
    /// visualization without going through the engine.
    private func attitudeEuler(motion: GCMotion) -> (roll: Float, pitch: Float, yaw: Float) {
        guard motion.hasAttitude else { return (0, 0, 0) }
        let q = motion.attitude
        let qx = Float(q.x), qy = Float(q.y), qz = Float(q.z), qw = Float(q.w)
        let roll  = atan2(2 * (qw * qx + qy * qz),
                          1 - 2 * (qx * qx + qy * qy))
        let pitchArg = 2 * (qw * qy - qz * qx)
        let pitch = asin(max(-1, min(1, pitchArg)))
        let yaw   = atan2(2 * (qw * qz + qx * qy),
                          1 - 2 * (qy * qy + qz * qz))
        return (roll, pitch, yaw)
    }

    private func availabilityBadge(label: String, available: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(available ? .green : .red.opacity(0.6))
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func sensorRow(label: String,
                           values: (Float, Float, Float),
                           scale: Float,
                           unit: String,
                           color: Color) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 42, alignment: .leading)
                .foregroundStyle(.secondary)
            sensorAxisCell(axis: "X", value: values.0, scale: scale, unit: unit, color: color)
            sensorAxisCell(axis: "Y", value: values.1, scale: scale, unit: unit, color: color)
            sensorAxisCell(axis: "Z", value: values.2, scale: scale, unit: unit, color: color)
        }
    }

    private func sensorAxisCell(axis: String,
                                value: Float,
                                scale: Float,
                                unit: String,
                                color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(axis)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10, alignment: .leading)
                Text(String(format: "%+0.2f", value))
                    .font(.caption.monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            MotionBar(value: value, scale: scale, tint: color)
                .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gyroscope")
                .font(.title)
                .iconTint(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Motion Calibration")
                    .font(.title2.weight(.semibold))
                Text("Sets the resting gyroscope and accelerometer zero for each controller so motion-driven presets don't drift.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Controller picker

    private var motionCapableControllers: [(slot: Int, controller: GCController, info: ControllerInfo)] {
        var result: [(Int, GCController, ControllerInfo)] = []
        for (slot, controller) in controllerService.connectedControllers.enumerated() {
            if let info = controllerService.controllerDetails[slot], info.supportsMotion {
                result.append((slot, controller, info))
            }
        }
        return result
    }

    @ViewBuilder
    private var controllerPicker: some View {
        if motionCapableControllers.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Connect a controller with motion sensors (DualSense, DualShock 4, Switch Pro, Joy-Con) to calibrate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Controller")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(motionCapableControllers, id: \.slot) { entry in
                    let key = MotionCalibrationService.identityKey(for: entry.controller)
                    let calibrated = MotionCalibrationService.shared.isCalibrated(forKey: key)
                    Button {
                        selectedKey = key
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selectedKey == key ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selectedKey == key ? Color.accentColor : Color.secondary)
                            Text(entry.controller.vendorName ?? "Controller")
                                .font(.body)
                            Spacer()
                            if calibrated {
                                Label("Calibrated", systemImage: "checkmark.seal.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                            } else {
                                Label("Needs calibration", systemImage: "exclamationmark.triangle.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedKey == key ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .onAppear {
                if selectedKey == nil, let first = motionCapableControllers.first {
                    selectedKey = MotionCalibrationService.identityKey(for: first.controller)
                }
            }
            .onDisappear {
                // Stop and discard any in-flight capture so a calibration the
                // user walked away from is never finished or persisted.
                captureTimer?.invalidate()
                captureTimer = nil
                captureInProgress = false
            }
        }
    }

    // MARK: - Instructions

    @ViewBuilder
    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How to calibrate")
                .font(.subheadline.weight(.semibold))
            stepRow(number: 1, text: "Place the controller on a flat, level surface (a desk works well).")
            stepRow(number: 2, text: "Make sure it's not vibrating - turn off rumble and don't touch the controller during capture.")
            stepRow(number: 3, text: "Click Start. InputConfig records the resting gyro and accelerometer values for \(Int(captureDuration)) seconds.")
            stepRow(number: 4, text: "The recorded zero is saved for this controller and used automatically by any motion-driven preset.")
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Capture surface

    @ViewBuilder
    private var captureSurface: some View {
        if captureInProgress {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                        .foregroundStyle(.teal)
                    Text("Place the controller FLAT on a level surface and don't touch it.")
                        .font(.callout.weight(.medium))
                }
                ProgressView(value: 1 - (captureRemaining / captureDuration))
                    .frame(maxWidth: .infinity)
                Text("Hold still… \(Int(ceil(captureRemaining))) s")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.10)))
        } else if let key = lastSavedKey, key == selectedKey {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Calibration saved. Motion bindings now use the corrected zero.")
                    .font(.callout)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerButtons: some View {
        HStack {
            if let key = selectedKey,
               MotionCalibrationService.shared.isCalibrated(forKey: key) {
                Button(role: .destructive) {
                    MotionCalibrationService.shared.clear(forKey: key)
                    lastSavedKey = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            Spacer()
            if awaitingConfirmation && !captureInProgress {
                Button("Cancel") {
                    withAnimation { awaitingConfirmation = false }
                }
                .buttonStyle(.solidSecondary)
                .keyboardShortcut(.cancelAction)
            } else {
                Button("Close") { dismiss() }
                    .buttonStyle(.solidSecondary)
                    .keyboardShortcut(.cancelAction)
            }

            // Two-step button:
            //   - idle           -> "Start Calibration" (accent tint).
            //                       First click scrolls the How-To into
            //                       view and morphs the button to green.
            //   - awaitingConfirm-> "Start Calibration" (green tint).
            //                       Second click runs the capture and
            //                       scrolls back to live readings.
            //   - capturing      -> "Capturing..." progress.
            Button {
                if captureInProgress { return }
                if !awaitingConfirmation {
                    withAnimation { awaitingConfirmation = true }
                } else {
                    awaitingConfirmation = false
                    startCapture()
                }
            } label: {
                if captureInProgress {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Capturing…")
                    }
                } else if awaitingConfirmation {
                    Label("Start Calibration", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Start Calibration", systemImage: "play.fill")
                }
            }
            .buttonStyle(SolidButton(tint: awaitingConfirmation ? .green : .accentColor))
            .disabled(selectedKey == nil || captureInProgress)
            .animation(.easeOut(duration: 0.18), value: awaitingConfirmation)
        }
    }

    // MARK: - Capture logic

    private func startCapture() {
        guard let key = selectedKey,
              let entry = motionCapableControllers.first(where: { MotionCalibrationService.identityKey(for: $0.controller) == key }),
              let motion = entry.controller.motion else { return }

        captureInProgress = true
        captureRemaining = captureDuration
        captureSamples.removeAll(keepingCapacity: true)
        lastSavedKey = nil
        // Snap the 3D model to absolute flat at the start of calibration
        // so the user has a clear visual reference for what "flat" means.
        // The integrator loop (further down) keeps these at zero while
        // captureInProgress is true.
        integratedRoll = 0
        integratedPitch = 0
        integratedYaw = 0

        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { t in
            // Sample motion on each tick.
            let s = SampleVector(
                gx: motion.hasRotationRate ? Float(motion.rotationRate.x) : 0,
                gy: motion.hasRotationRate ? Float(motion.rotationRate.y) : 0,
                gz: motion.hasRotationRate ? Float(motion.rotationRate.z) : 0,
                ax: Float(motion.userAcceleration.x),
                ay: Float(motion.userAcceleration.y),
                az: Float(motion.userAcceleration.z)
            )
            captureSamples.append(s)
            captureRemaining = max(0, captureDuration - Date().timeIntervalSince(start))
            if captureRemaining <= 0 {
                t.invalidate()
                captureTimer = nil
                finishCapture(key: key)
            }
        }
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishCapture(key: String) {
        defer {
            captureInProgress = false
            captureRemaining = 0
        }
        guard !captureSamples.isEmpty else { return }
        let n = Float(captureSamples.count)
        let gx = captureSamples.map(\.gx).reduce(0, +) / n
        let gy = captureSamples.map(\.gy).reduce(0, +) / n
        let gz = captureSamples.map(\.gz).reduce(0, +) / n
        let ax = captureSamples.map(\.ax).reduce(0, +) / n
        let ay = captureSamples.map(\.ay).reduce(0, +) / n
        let az = captureSamples.map(\.az).reduce(0, +) / n
        let cal = MotionCalibration(
            controllerKey: key,
            gyroDriftX: gx, gyroDriftY: gy, gyroDriftZ: gz,
            accelDriftX: ax, accelDriftY: ay, accelDriftZ: az,
            savedAt: Date()
        )
        MotionCalibrationService.shared.save(cal)
        lastSavedKey = key
    }
}

/// Tiny bidirectional bar used by the live sensor readout. Center is zero,
/// the bar fills right for positive values and left for negative, clamped
/// to ±`scale` so a vigorous shake still stays inside the bar.
private struct MotionBar: View {
    let value: Float
    let scale: Float
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let halfWidth = width / 2
            let clamped = max(-1, min(1, value / max(scale, 0.0001)))
            let barWidth = abs(CGFloat(clamped)) * halfWidth

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint.opacity(0.15))

                Rectangle()
                    .fill(tint)
                    .frame(width: barWidth, height: geo.size.height)
                    .offset(x: clamped >= 0 ? halfWidth : halfWidth - barWidth)

                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1)
                    .offset(x: halfWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}
