import SwiftUI
import AppKit

// MARK: - Spotlight anchor plumbing

/// Identifier used to tag a UI element so the tutorial can highlight it.
/// Each step references one of these by string id; ContentView attaches
/// `.spotlightAnchor("...")` to the matching element and the overlay reads
/// the global frame from a PreferenceKey.
enum SpotlightID {
    static let sidebar          = "sidebar"
    static let homeButton       = "home-button"
    static let statsButton      = "stats-button"
    static let settingsButton   = "settings-button"
    static let detailHeader     = "detail-header"
    static let editButton       = "edit-button"
    static let activateButton   = "activate-button"
    static let visualizer       = "visualizer"
    static let customizeButton  = "customize-button"
    static let lightBarStrip    = "light-bar-strip"
    static let notesSection     = "notes-section"
    static let createNew        = "create-new-preset"
    static let welcomeCard      = "welcome-card-showcase"
    // Anchors added for the Minecraft hands-on walkthrough at the end
    // of the Quick Tour. Each one is attached to a real UI element so
    // the spotlight ring lands on the exact thing being explained.
    static let automationPanel  = "automation-panel"
    static let templatePicker   = "template-picker"
    static let slotChip         = "slot-chip"
    static let importButton     = "import-button"
    static let editorSave       = "editor-save"
    static let editorCancel     = "editor-cancel"
}

struct SpotlightAnchor: Equatable {
    let id: String
    let frame: CGRect
}

struct SpotlightAnchorsKey: PreferenceKey {
    static var defaultValue: [SpotlightAnchor] { [] }
    static func reduce(value: inout [SpotlightAnchor],
                       nextValue: () -> [SpotlightAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

/// Reports this view's global frame as a spotlight anchor, but ONLY while a
/// tutorial is actually running. When no tutorial is active (the normal case,
/// and always during real use) it installs nothing - no GeometryReader, no
/// global-frame preference - so the ~20 anchored views cost zero per-frame
/// layout work. Leaving the readers always-on made every layout pass
/// re-evaluate 20 global frames; in the large binding editor that never
/// settled and hung the main thread.
private struct SpotlightAnchorModifier: ViewModifier {
    let id: String
    @ObservedObject private var tutorial = TutorialState.shared

    func body(content: Content) -> some View {
        if tutorial.isActive {
            content.background(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: SpotlightAnchorsKey.self,
                            value: [SpotlightAnchor(id: id, frame: geo.frame(in: .global))]
                        )
                }
            )
        } else {
            content
        }
    }
}

extension View {
    func spotlightAnchor(_ id: String) -> some View {
        modifier(SpotlightAnchorModifier(id: id))
    }
}

// MARK: - Tutorial step + demo

enum TutorialDemoKind {
    case analogStick
    case pressureTrigger
    case gyro
    case lightBar
    case macroChain
    case buttonMapping
}

enum SpotlightShape {
    case roundedRect
    case circle
}

struct TutorialStep: Identifiable {
    let id = UUID()
    let icon: String
    let tint: Color
    let title: String
    let body: String
    var spotlight: String? = nil
    var spotlightShape: SpotlightShape = .roundedRect
    var demo: TutorialDemoKind? = nil
    var tip: String? = nil
    var action: (() -> Void)? = nil
}

// MARK: - Shared tutorial state

/// App-wide tutorial controller. Owns the step list and current position
/// so both the spotlight overlay (in the main window) and the floating
/// card panel (in its own NSPanel) can observe it.
@MainActor
final class TutorialState: ObservableObject {
    static let shared = TutorialState()

    @Published var isActive: Bool = false
    @Published var stepIndex: Int = 0
    @Published private(set) var steps: [TutorialStep] = []

    /// Anchor ID the simulated cursor is currently animating toward.
    /// nil = no demo cursor visible. TutorialOverlay reads this and
    /// the spotlight anchor preference dict to position a fake cursor
    /// that flies to the target before the step's UI action fires.
    @Published private(set) var simulatedClickTarget: String?
    /// Marks the simulated click as actually "depressing" the button
    /// (small cursor scale-down + ring pulse). Flips true 0.55 s
    /// after the cursor lands; cleared along with the target when
    /// the animation completes.
    @Published private(set) var simulatedClickPressed: Bool = false

    private init() {}

    /// Start the tour. Spins up the floating panel so the card sits
    /// above any sheets that get opened along the way.
    func start(steps: [TutorialStep]) {
        self.steps = steps
        self.stepIndex = 0
        self.isActive = true
        steps.first?.action?()
        TutorialWindowController.shared.show()
    }

    func stop() {
        isActive = false
        TutorialWindowController.shared.hide()
    }

    func next() {
        if stepIndex + 1 >= steps.count {
            stop()
        } else {
            stepIndex += 1
            steps[stepIndex].action?()
        }
    }

    func back() {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
        steps[stepIndex].action?()
    }

    var currentStep: TutorialStep? {
        guard isActive, stepIndex < steps.count else { return nil }
        return steps[stepIndex]
    }

    /// Standard pattern for tour steps that auto-perform a UI action:
    /// first move a simulated cursor to the target button, depress it,
    /// then fire `action`. Lets the user see WHERE the action lands
    /// instead of a sheet appearing from nowhere.
    ///
    /// Timeline (total ≈1.4 s):
    ///   0.00s - cursor appears, starts gliding to anchor
    ///   0.55s - cursor "presses" (scale + ring pulse)
    ///   0.95s - action() fires
    ///   1.20s - cursor fades out
    func simulateClickThen(at anchorID: String,
                            action: @escaping () -> Void) {
        simulatedClickPressed = false
        simulatedClickTarget = anchorID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.simulatedClickPressed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            action()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.simulatedClickTarget = nil
            self?.simulatedClickPressed = false
        }
    }
}

// MARK: - Tutorial overlay (spotlight only; lives in main window)

/// In-window overlay - draws ONLY the spotlight dim/cutout. The actual
/// tutorial card now lives in a floating NSPanel so it can sit above
/// sheets that the user opens during the tour. This way the main window
/// keeps its highlight ring AND the card is always reachable.
struct TutorialOverlay: View {
    @ObservedObject var state: TutorialState
    let anchors: [String: CGRect]

    var body: some View {
        ZStack {
            // Spotlight dim/cutout.
            if let step = state.currentStep,
               let id = step.spotlight,
               let rect = anchors[id] {
                SpotlightDimView(rect: rect, shape: step.spotlightShape)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.22), value: state.stepIndex)
            }
            // Simulated cursor flying to a target anchor. Tour steps
            // that auto-perform UI actions trigger this so the user
            // sees WHERE the click landed before the sheet opens.
            if let target = state.simulatedClickTarget,
               let rect = anchors[target] {
                SimulatedCursor(targetCenter: CGPoint(x: rect.midX, y: rect.midY),
                                pressed: state.simulatedClickPressed)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}

/// A fake mouse cursor that flies from a slightly-off-screen anchor
/// to the target frame's center, then "presses" (shrinks slightly +
/// emits a ring pulse) when `pressed` flips true. Stylized to read as
/// a system pointer without conflicting with the real cursor.
fileprivate struct SimulatedCursor: View {
    let targetCenter: CGPoint
    let pressed: Bool
    @State private var landed: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Click-ring pulse, fires when pressed flips true.
            Circle()
                .stroke(Color.green.opacity(pressed ? 0.0 : 0.6),
                        lineWidth: 2)
                .frame(width: pressed ? 64 : 20,
                       height: pressed ? 64 : 20)
                .opacity(pressed ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: pressed)
            // Cursor arrow icon.
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3, x: 1, y: 2)
                .scaleEffect(pressed ? 0.85 : 1.0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: pressed)
        }
        // Under Reduce Motion the cursor is placed directly on the target
        // instead of gliding in from off-screen.
        .position((landed || reduceMotion)
                    ? targetCenter
                    : CGPoint(x: targetCenter.x - 220,
                              y: targetCenter.y - 140))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: landed)
        .accessibilityHidden(true)
        .onAppear {
            // Start off-screen, then glide to the target on the next
            // runloop tick so SwiftUI sees the position change. Skipped
            // when Reduce Motion is on since the cursor is already placed.
            if !reduceMotion {
                DispatchQueue.main.async { landed = true }
            }
        }
    }
}

// MARK: - Floating panel card

/// Card content. Rendered inside both the floating panel (always-on-top)
/// AND any place else that wants the same UI. Pulls everything from
/// TutorialState.shared so it stays in sync with the overlay.
struct TutorialCardView: View {
    @ObservedObject var state = TutorialState.shared

    var body: some View {
        if let step = state.currentStep {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: step.icon)
                        .font(.title2)
                        .foregroundStyle(step.tint)
                        .frame(width: 32, height: 32)
                        .background(step.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Quick Start - \(state.stepIndex + 1) of \(state.steps.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(step.title)
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button {
                        state.stop()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Skip tutorial")
                    .accessibilityLabel("Skip tutorial")
                    .accessibilityHint("Closes the quick start tour")
                }

                Text(step.body)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let demo = step.demo {
                    TutorialDemoView(kind: demo)
                        .padding(.vertical, 4)
                }

                if let tip = step.tip {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text(tip)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                progressBar(current: state.stepIndex + 1, total: state.steps.count)

                HStack(spacing: 8) {
                    Button("Skip") {
                        state.stop()
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .foregroundStyle(.secondary)
                    // The header close button already exposes a single
                    // "Skip tutorial" action to VoiceOver; hide this
                    // duplicate so assistive tech surfaces only one.
                    .accessibilityHidden(true)

                    Spacer()

                    if state.stepIndex > 0 {
                        Button {
                            state.back()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.solidSecondary)
                    }

                    Button {
                        state.next()
                    } label: {
                        if state.stepIndex + 1 >= state.steps.count {
                            Label("Finish", systemImage: "checkmark")
                                .labelStyle(.titleAndIcon)
                        } else {
                            Label("Next", systemImage: "chevron.right")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .buttonStyle(.solid)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(18)
            .frame(width: 400)
            .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                    .stroke(step.tint.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        }
    }

    private func progressBar(current: Int, total: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i < current ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 4)
            }
        }
    }
}

// MARK: - Floating NSPanel controller

/// Floating panel that hosts the tutorial card above any sheets. Uses
/// .floating window level + .nonactivatingPanel so the user can click
/// Next on the card without losing focus on whatever's underneath.
@MainActor
final class TutorialWindowController {
    static let shared = TutorialWindowController()
    private var panel: NSPanel?

    private init() {}

    func show() {
        if let p = panel {
            // Don't re-position on subsequent shows - the user may have
            // dragged the card and we want Next to stay where they put it.
            p.orderFront(nil)
            return
        }
        // Truly borderless + non-activating + floating. No .titled means
        // no chrome (which was creating the weird jagged corners the
        // user pointed at on the screenshot).
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false  // The SwiftUI card draws its own shadow.

        // SwiftUI card inside an NSHostingView. Outer padding ensures the
        // card's shadow has room to breathe inside the hosting view.
        let host = NSHostingView(rootView:
            TutorialCardView()
                .padding(20)
                .reduceMotionFriendly()
        )
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        position(panel: p)
        p.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// One-time positioning at the bottom-trailing corner of the screen
    /// (not the main window) so the panel stays put even if the user
    /// resizes or moves the window during the tour. Next + Skip always
    /// land at the same spot.
    private func position(panel: NSPanel) {
        let target: NSRect
        if let screen = NSScreen.main?.visibleFrame {
            target = screen
        } else if let main = NSApp.mainWindow {
            target = main.frame
        } else {
            return
        }
        let pf = panel.frame
        let origin = NSPoint(
            x: target.maxX - pf.width - 24,
            y: target.minY + 24
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Tutorial plumbing modifier

/// Bundles the tutorial-specific modifiers (spotlight overlay,
/// anchor-collection preference reader, end-of-tour cleanup) into one
/// ViewModifier so ContentView's body doesn't blow Swift's type-checker.
struct TutorialPlumbing: ViewModifier {
    @ObservedObject var state: TutorialState
    @Binding var anchors: [String: CGRect]
    let onTutorialEnded: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                TutorialOverlay(state: state, anchors: anchors)
            }
            .onPreferenceChange(SpotlightAnchorsKey.self) { values in
                var dict: [String: CGRect] = [:]
                for a in values { dict[a.id] = a.frame }
                anchors = dict
            }
            .onChange(of: state.isActive) { _, isActive in
                if !isActive { onTutorialEnded() }
            }
    }
}

// MARK: - Spotlight dim layer

struct SpotlightDimView: View {
    let rect: CGRect
    var shape: SpotlightShape = .roundedRect
    @State private var pulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let local = CGRect(
                x: rect.minX - geo.frame(in: .global).minX - 8,
                y: rect.minY - geo.frame(in: .global).minY - 8,
                width: rect.width + 16,
                height: rect.height + 16
            )
            let isCircle = shape == .circle
            let circleSize = max(local.width, local.height)
            let cutoutWidth = isCircle ? circleSize : local.width
            let cutoutHeight = isCircle ? circleSize : local.height

            ZStack {
                Color.black.opacity(0.55)
                    .mask(
                        Rectangle()
                            .overlay(
                                Group {
                                    if isCircle {
                                        Circle()
                                    } else {
                                        RoundedRectangle(cornerRadius: 12)
                                    }
                                }
                                .frame(width: cutoutWidth, height: cutoutHeight)
                                .position(x: local.midX, y: local.midY)
                                .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )

                // When Reduce Motion is on, draw a static highlighted ring
                // (no repeating pulse) so the target is still clearly marked
                // without any looping animation.
                let ringActive = reduceMotion ? true : pulse
                Group {
                    if isCircle {
                        Circle()
                            .stroke(Color.accentColor, lineWidth: ringActive ? 3 : 1.5)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentColor, lineWidth: ringActive ? 3 : 1.5)
                    }
                }
                .frame(width: cutoutWidth, height: cutoutHeight)
                .position(x: local.midX, y: local.midY)
                .opacity(ringActive ? 0.9 : 0.55)
                .shadow(color: .accentColor.opacity(0.6), radius: ringActive ? 12 : 6)
                .animation(reduceMotion
                           ? nil
                           : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: pulse)
                .onAppear {
                    if !reduceMotion { pulse = true }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Inline demos

struct TutorialDemoView: View {
    let kind: TutorialDemoKind

    /// Short, stable description of each looping demo so VoiceOver reads
    /// one meaningful element instead of the constantly-changing numbers
    /// the animation produces.
    private var accessibilityDescription: String {
        switch kind {
        case .analogStick:     return "Analog stick demonstration, showing smooth analog values"
        case .pressureTrigger: return "Pressure-sensitive trigger demonstration"
        case .gyro:            return "3D motion model demonstration, mirroring controller orientation"
        case .lightBar:        return "Per-preset light bar demonstration, cycling through colors"
        case .macroChain:      return "Macro chain demonstration, highlighting each key in sequence"
        case .buttonMapping:   return "Button mapping demonstration, mapping the A button to Space"
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .analogStick:     AnalogStickDemo()
            case .pressureTrigger: PressureTriggerDemo()
            case .gyro:            InlineGyroDemo()
            case .lightBar:        LightBarDemo()
            case .macroChain:      MacroChainDemo()
            case .buttonMapping:   ButtonMappingDemo()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}

private struct AnalogStickDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || AppA11y.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let x = CGFloat(cos(t * 1.5))
            let y = CGFloat(sin(t * 1.5))
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    Path { p in
                        p.move(to: CGPoint(x: 36, y: 0)); p.addLine(to: CGPoint(x: 36, y: 72))
                        p.move(to: CGPoint(x: 0, y: 36)); p.addLine(to: CGPoint(x: 72, y: 36))
                    }
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 14)
                        .offset(x: x * 26, y: y * 26)
                }
                .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smooth analog values").font(.caption.weight(.semibold))
                    Text("X: \(String(format: "%+0.2f", x))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("Y: \(String(format: "%+0.2f", y))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct PressureTriggerDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || AppA11y.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let v = CGFloat(abs(sin(t * 1.2)))
            HStack(spacing: 14) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 24, height: 84)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue.gradient)
                        .frame(width: 24, height: max(2, v * 84))
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 28, height: 1)
                        .offset(y: -25)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pressure-sensitive trigger").font(.caption.weight(.semibold))
                    Text("Magnitude: \(Int(v * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Rectangle().fill(.orange).frame(width: 8, height: 2)
                        Text("deadzone")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct InlineGyroDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || AppA11y.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let yaw   = Float(sin(t / 3.5 * 2 * .pi))
            let pitch = Float(sin(t / 2.2 * 2 * .pi))
            let roll  = Float(sin(t / 4.1 * 2 * .pi))
            HStack(spacing: 12) {
                GyroVisualizationView(
                    gyroX: pitch * 1.2,
                    gyroY: yaw * 1.2,
                    gyroZ: roll * 0.8,
                    rollAngle: roll * 0.35,
                    pitchAngle: pitch * 0.35,
                    yawAngle: yaw * 0.45,
                    mode: .compact
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("3D motion model").font(.caption.weight(.semibold))
                    Text("Mirrors the real controller orientation in real time.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct LightBarDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || AppA11y.reduceMotion)) { ctx in
            let hue = (ctx.date.timeIntervalSinceReferenceDate / 4)
                .truncatingRemainder(dividingBy: 1)
            let color = Color(hue: hue, saturation: 0.9, brightness: 1)
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [color.opacity(0.85), color, color.opacity(0.85)],
                                             startPoint: .leading, endPoint: .trailing))
                        .shadow(color: color.opacity(0.7), radius: 6)
                }
                .frame(width: 110, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Per-preset light bar").font(.caption.weight(.semibold))
                    Text("Auto-applies when the preset activates; reverts on stop.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct MacroChainDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let keys = ["⌘", "C", "⌥", "Tab"]
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || AppA11y.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let active = Int(t * 1.5) % keys.count
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(keys.indices, id: \.self) { i in
                        Text(keys[i])
                            .font(.caption.weight(.semibold).monospaced())
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(i == active ? Color.yellow.opacity(0.4)
                                                      : Color.secondary.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(i == active ? Color.yellow : Color.secondary.opacity(0.3),
                                            lineWidth: 1)
                            )
                            .animation(.easeOut(duration: 0.2), value: active)
                    }
                }
                Text("Macro chain")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ButtonMappingDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || AppA11y.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pressed = sin(t * 2) > 0
            HStack(spacing: 12) {
                Circle()
                    .fill(pressed ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay(Text("A").font(.caption.weight(.semibold)))
                    .shadow(color: pressed ? .green.opacity(0.7) : .clear, radius: 8)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                Text(pressed ? "Space" : " ")
                    .font(.caption.weight(.semibold).monospaced())
                    .frame(width: 60, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(pressed ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.12))
                    )
                Spacer(minLength: 0)
            }
        }
    }
}
