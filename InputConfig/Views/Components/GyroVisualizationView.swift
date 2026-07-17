import SwiftUI
import SceneKit
import AppKit

/// Shared 3D-tilt + attitude-horizon gyro visualization. Used by:
///
/// * `VirtualControllerView` (compact, alongside other widgets)
/// * `MotionCalibrationView` (regular, while previewing live readings)
/// * `FeatureDemoView` / GyroDemo (large, animated welcome demo)
///
/// Renders a stylized controller silhouette that tilts in 3D via
/// `rotation3DEffect`, plus an attitude-indicator ring with a horizon line
/// that pitches and rolls, plus three small bars showing instantaneous
/// angular-rate magnitude on each gyro axis (color-coded: red X, green Y,
/// blue Z).
struct GyroVisualizationView: View {
    /// Instantaneous angular velocity around each axis (radians / second).
    /// Drives the rate bars at the bottom of the widget.
    let gyroX: Float
    let gyroY: Float
    let gyroZ: Float

    /// Absolute attitude in radians. When the controller exposes
    /// `hasAttitude`, callers pass through Euler-derived roll/pitch/yaw so
    /// the silhouette can hold its real-world orientation instead of
    /// drifting from integrated rates.
    var rollAngle: Float = 0
    var pitchAngle: Float = 0
    var yawAngle: Float = 0

    /// Rendering size preset. Compact strips labels and rate bars to fit
    /// inside the controller visualizer; regular shows everything; large
    /// gets extra padding for the demo cards.
    enum Mode { case compact, regular, large }
    var mode: Mode = .regular

    /// Base size of the attitude ring. Other sub-views scale relative to
    /// this so changes here affect everything proportionally.
    private var ringSize: CGFloat {
        switch mode {
        case .compact: return 60
        case .regular: return 130
        case .large:   return 170
        }
    }

    private var silhouetteSize: CGFloat {
        switch mode {
        case .compact: return 24
        case .regular: return 56
        case .large:   return 76
        }
    }

    private var barHeight: CGFloat { mode == .compact ? 3 : 5 }

    // MARK: - Body

    var body: some View {
        VStack(spacing: mode == .compact ? 4 : 10) {
            attitudeRing
            if mode != .compact {
                rateBars
                    .frame(maxWidth: ringSize)
            }
        }
    }

    // MARK: - Attitude ring

    /// Circular "artificial horizon" - sky tints upper half, ground tints
    /// lower half, and the horizon line tilts with roll while sliding
    /// vertically with pitch. Controller silhouette sits centered and
    /// tilts in 3D so it feels like the physical controller in your hand.
    private var attitudeRing: some View {
        ZStack {
            // Sky / ground gradient slices that shift with pitch.
            attitudeHorizon
                .clipShape(Circle())

            // Faint tick marks every 30 degrees around the ring.
            ForEach(0..<12) { i in
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: 6)
                    .offset(y: -ringSize / 2 + 4)
                    .rotationEffect(.degrees(Double(i) * 30))
            }

            // Outer ring.
            Circle()
                .stroke(Color.teal.opacity(0.55), lineWidth: 1.5)

            // True 3D controller mesh, rendered with SceneKit. Rotates in
            // real time on the actual pitch/yaw/roll values - so the model
            // mirrors how the physical controller is being held. Far more
            // convincing than a flat SF Symbol with a rotation effect on
            // top.
            Controller3DSceneView(
                pitchAngle: pitchAngle,
                yawAngle: yawAngle,
                rollAngle: rollAngle,
                // Gyro rate magnitude above a small noise deadband = tilting.
                isMoving: abs(gyroX) + abs(gyroY) + abs(gyroZ) > 0.03
            )
            .frame(width: silhouetteSize * 1.6, height: silhouetteSize * 1.2)
            .shadow(color: .teal.opacity(0.4), radius: 4)

            // Center crosshair so the eye has an "origin" even when the
            // controller silhouette is tilting away.
            Circle()
                .stroke(Color.primary.opacity(0.35), lineWidth: 0.5)
                .frame(width: 6, height: 6)
        }
        .frame(width: ringSize, height: ringSize)
    }

    /// Horizon shading: cyan sky on top, brown ground on bottom, with a
    /// thin horizon line. The whole composition rotates with roll and
    /// shifts up/down with pitch.
    private var attitudeHorizon: some View {
        // Pitch offset: pi/2 (90 deg) nose-up moves the horizon to the
        // bottom of the ring, pi/2 nose-down to the top. Clamp for safety.
        let pitchOffset = CGFloat(max(-1, min(1, pitchAngle / (.pi / 2)))) * (ringSize / 2)

        return ZStack {
            // Sky.
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.30, green: 0.55, blue: 0.85),
                             Color(red: 0.20, green: 0.45, blue: 0.75)],
                    startPoint: .top, endPoint: .bottom))
                .frame(height: ringSize)
                .offset(y: -ringSize / 2)

            // Ground.
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.55, green: 0.40, blue: 0.25),
                             Color(red: 0.40, green: 0.28, blue: 0.18)],
                    startPoint: .top, endPoint: .bottom))
                .frame(height: ringSize)
                .offset(y: ringSize / 2)

            // Horizon line.
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: ringSize * 1.4, height: 1.5)
        }
        .offset(y: pitchOffset)
        .rotationEffect(.radians(Double(rollAngle)))
        .animation(.easeOut(duration: 0.05), value: rollAngle)
        .animation(.easeOut(duration: 0.05), value: pitchAngle)
    }

    // MARK: - Rate bars

    /// Three horizontal bars showing the instantaneous angular-rate
    /// magnitude on each gyro axis. Color-coded so it's easy to tell which
    /// axis is moving at a glance: red = X (pitch), green = Y (yaw),
    /// blue = Z (roll).
    private var rateBars: some View {
        VStack(spacing: 4) {
            rateRow(label: "X", value: gyroX, color: .red)
            rateRow(label: "Y", value: gyroY, color: .green)
            rateRow(label: "Z", value: gyroZ, color: .blue)
        }
    }

    /// Single rate row: label, bidirectional bar with center tick, value.
    private func rateRow(label: String, value: Float, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)

            GeometryReader { geo in
                let halfWidth = geo.size.width / 2
                let clamped = max(-1, min(1, CGFloat(value) / 5.0))
                let barWidth = abs(clamped) * halfWidth

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.15))
                    Rectangle()
                        .fill(color)
                        .frame(width: barWidth, height: barHeight)
                        .offset(x: clamped >= 0 ? halfWidth : halfWidth - barWidth)
                    Rectangle()
                        .fill(Color.primary.opacity(0.4))
                        .frame(width: 1)
                        .offset(x: halfWidth)
                }
                .clipShape(Capsule())
            }
            .frame(height: barHeight)

            Text(String(format: "%+0.2f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

#Preview("Regular") {
    GyroVisualizationView(gyroX: 0.5, gyroY: -0.3, gyroZ: 0.1,
                          rollAngle: 0.25, pitchAngle: 0.15, yawAngle: -0.1,
                          mode: .regular)
        .padding()
}

#Preview("Compact") {
    GyroVisualizationView(gyroX: 0.5, gyroY: -0.3, gyroZ: 0.1,
                          rollAngle: 0.25, pitchAngle: 0.15, yawAngle: -0.1,
                          mode: .compact)
        .padding()
}

// MARK: - SceneKit 3D controller

/// Real 3D controller mesh, rendered via SceneKit so rotation looks like
/// genuine depth (parallax, lighting changes) instead of a flat icon being
/// tilted. Built from primitive geometry - a chamfered box body, two stick
/// cylinders, four colored face buttons, and two shoulder boxes - so we
/// don't need an asset file. Updates the node's Euler angles in real time
/// from the gyro view's pitch / yaw / roll inputs.
struct Controller3DSceneView: NSViewRepresentable {
    let pitchAngle: Float
    let yawAngle: Float
    let rollAngle: Float
    /// True while the controller is actually tilting. Continuous rendering is
    /// only needed to present small per-frame deltas during motion; when the
    /// controller is still there is nothing to present, so we drop to
    /// on-demand rendering and let SceneKit hold the last frame. This stops the
    /// SCNView's independent 30 fps CVDisplayLink from running forever whenever
    /// a motion controller is merely connected.
    var isMoving: Bool = true

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = buildScene()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        // Start continuous so the very first frame is guaranteed to present;
        // updateNSView (called immediately after, and on every angle change)
        // then gates it to `isMoving`. isPlaying stays on so on-demand redraws
        // still fire when the scene graph changes.
        view.rendersContinuously = true
        view.isPlaying = true
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        // Only keep the render loop hot while the controller is moving. The
        // first frame already presented (makeNSView started continuous), and
        // any angle change re-runs this to present it; when still we hold the
        // last frame, which is pixel-identical to the current always-rendered
        // still frame.
        nsView.rendersContinuously = isMoving
        guard let node = nsView.scene?.rootNode.childNode(withName: "controller",
                                                          recursively: true) else { return }
        // GCMotion convention: X = pitch, Y = yaw, Z = roll. SceneKit uses
        // Euler angles in the same order so the mapping is direct. Slight
        // sign flip on yaw so tilting the controller right makes the model
        // visually point right. Wrap in SCNTransaction so the angle update
        // commits this frame and SceneKit interpolates smoothly between
        // ticks.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.05
        node.eulerAngles = SCNVector3(
            CGFloat(pitchAngle),
            CGFloat(-yawAngle),
            CGFloat(rollAngle)
        )
        SCNTransaction.commit()
    }

    /// Build the stylized controller mesh + camera + lighting once. Geometry
    /// is intentionally low-poly so it stays cheap to render at 30 fps.
    private func buildScene() -> SCNScene {
        let scene = SCNScene()

        // Body - rounded box with a soft teal material.
        let body = SCNBox(width: 2.4, height: 0.45, length: 1.0, chamferRadius: 0.18)
        body.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.16, green: 0.55, blue: 0.62, alpha: 1)
        body.firstMaterial?.specular.contents = NSColor(white: 0.85, alpha: 1)
        body.firstMaterial?.shininess = 0.65
        body.firstMaterial?.emission.contents = NSColor(calibratedRed: 0.04, green: 0.18, blue: 0.20, alpha: 1)

        let bodyNode = SCNNode(geometry: body)
        bodyNode.name = "controller"

        // Grips - two slightly tilted boxes on each end to give the body
        // its iconic controller silhouette in profile.
        for sign in [-1.0, 1.0] {
            let grip = SCNBox(width: 0.55, height: 0.55, length: 0.8, chamferRadius: 0.22)
            grip.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.12, green: 0.45, blue: 0.52, alpha: 1)
            grip.firstMaterial?.specular.contents = NSColor(white: 0.7, alpha: 1)
            grip.firstMaterial?.shininess = 0.5
            let gripNode = SCNNode(geometry: grip)
            gripNode.position = SCNVector3(1.05 * sign, -0.15, 0.05)
            gripNode.eulerAngles = SCNVector3(0, 0, -0.15 * sign)
            bodyNode.addChildNode(gripNode)
        }

        // Sticks - tall thin cylinders on the front face.
        for sign in [-1.0, 1.0] {
            let stickBase = SCNCylinder(radius: 0.16, height: 0.1)
            stickBase.firstMaterial?.diffuse.contents = NSColor.black
            let baseNode = SCNNode(geometry: stickBase)
            baseNode.position = SCNVector3(0.55 * sign, 0.22, 0.1)
            bodyNode.addChildNode(baseNode)

            let stickCap = SCNSphere(radius: 0.13)
            stickCap.firstMaterial?.diffuse.contents = NSColor(white: 0.18, alpha: 1)
            stickCap.firstMaterial?.specular.contents = NSColor(white: 0.9, alpha: 1)
            let capNode = SCNNode(geometry: stickCap)
            capNode.position = SCNVector3(0.55 * sign, 0.32, 0.1)
            bodyNode.addChildNode(capNode)
        }

        // Face buttons - 4 colored cylinders on the right.
        let buttonLayout: [(x: Float, z: Float, color: NSColor)] = [
            ( 0.0,  0.30, .systemYellow),   // top
            ( 0.0, -0.10, .systemGreen),    // bottom
            (-0.18, 0.10, .systemBlue),     // left
            ( 0.18, 0.10, .systemRed)       // right
        ]
        for entry in buttonLayout {
            let btn = SCNCylinder(radius: 0.08, height: 0.06)
            btn.firstMaterial?.diffuse.contents = entry.color
            btn.firstMaterial?.specular.contents = NSColor.white
            let btnNode = SCNNode(geometry: btn)
            btnNode.position = SCNVector3(0.95 + entry.x, 0.26, entry.z)
            bodyNode.addChildNode(btnNode)
        }

        // D-pad - small plus shape from two boxes.
        let dpadDims: [(w: Double, h: Double)] = [(0.28, 0.08), (0.08, 0.28)]
        for dim in dpadDims {
            let arm = SCNBox(width: CGFloat(dim.w), height: 0.04, length: CGFloat(dim.h), chamferRadius: 0.02)
            arm.firstMaterial?.diffuse.contents = NSColor(white: 0.2, alpha: 1)
            let armNode = SCNNode(geometry: arm)
            armNode.position = SCNVector3(-0.95, 0.24, 0.1)
            bodyNode.addChildNode(armNode)
        }

        // Shoulder buttons on the top edge.
        for sign in [-1.0, 1.0] {
            let shoulder = SCNBox(width: 0.42, height: 0.1, length: 0.2, chamferRadius: 0.05)
            shoulder.firstMaterial?.diffuse.contents = NSColor(white: 0.25, alpha: 1)
            let shoulderNode = SCNNode(geometry: shoulder)
            shoulderNode.position = SCNVector3(1.0 * sign, 0.3, -0.4)
            bodyNode.addChildNode(shoulderNode)
        }

        scene.rootNode.addChildNode(bodyNode)

        // Camera at a slight overhead angle so tilts are visible. The
        // built-in `look(at:)` keeps it pointed at the body's origin.
        let camera = SCNCamera()
        camera.fieldOfView = 35
        camera.zNear = 0.1
        camera.zFar = 50
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 2.8, 5.5)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        // Soft three-point lighting: ambient fill, key from upper-left, rim
        // from upper-right. Together they make the chamfered edges read as
        // 3D rather than flat-shaded.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.55, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = NSColor(calibratedRed: 0.95, green: 0.96, blue: 1.0, alpha: 1)
        key.light?.intensity = 950
        key.position = SCNVector3(-3, 5, 4)
        key.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.color = NSColor(calibratedRed: 0.65, green: 0.9, blue: 1.0, alpha: 1)
        rim.light?.intensity = 500
        rim.position = SCNVector3(4, 2, -4)
        rim.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(rim)

        return scene
    }
}
