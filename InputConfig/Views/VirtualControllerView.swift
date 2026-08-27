import SwiftUI
import QuartzCore

/// Live virtual-controller layout. Reads the latest `ControllerState` from
/// `GameControllerService.currentStates[slot]` at 30 Hz and renders each
/// physical input as a clickable widget:
///
///   • Sticks - circle with a thumb dot that tracks the analog X/Y
///   • Triggers - vertical bar with the live magnitude + the binding's
///     deadzone threshold marked as a horizontal line
///   • Face buttons - circles that flash green on press
///   • Shoulders / bumpers - pill shapes
///   • D-pad - cross with each arm lighting up when active
///   • Touchpad - rectangle showing finger 1 / 2 positions
///   • Motion - gyroscope orb showing yaw / pitch deflection
///
/// Tapping a widget opens a popover summarising any bindings in the
/// current preset that target that physical input, with a button to jump
/// into the preset editor focused on the relevant row.
struct VirtualControllerView<Trailing: View>: View {
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let preset: Preset
    /// Asks the host to open the preset editor and scroll/pulse the row that
    /// matches this input. Fired when the user clicks any matching binding
    /// in a widget popover, OR the "Jump to editor anyway" button when no
    /// binding currently targets the input.
    var onJump: ((EditorJumpTarget) -> Void)?

    /// Which controller slot this visualizer mirrors. Hosts may render
    /// one visualizer per connected controller and pass the slot in
    /// directly; the legacy slot picker is hidden when this is non-nil.
    var fixedSlot: Int?

    /// Content shown as a popover anchored to the light-bar strip on the
    /// controller. ContentView feeds the per-preset Light Bar editor here
    /// for controllers that have a real light bar (DualSense / DualShock 4).
    /// EmptyView for everyone else.
    @ViewBuilder var trailing: () -> Trailing

    /// Tint of the on-controller light-bar strip widget. ContentView
    /// computes this from the preset's `lightBarColor` override - nil =
    /// use a faint neutral fill so the strip is visible but obviously
    /// "unset". When set, the strip glows that color.
    var lightBarTint: Color? = nil

    /// Optional callback: when the user picks a new layout template
    /// from the inline visualizer picker, this fires with the slot
    /// and the new `SlotInputKind`. Host updates the preset model
    /// via the store. nil hides the picker.
    var onChangeInputKind: ((Int, SlotInputKind) -> Void)?

    /// User-adjustable size factor for the visualizer panel. Persisted in
    /// UserDefaults so the layout sticks across launches. Default 0.5 so
    /// the whole controller fits comfortably without zooming the user's
    /// window content out.
    @AppStorage("VirtualController.scale") private var visualizerScale: Double = 0.5

    /// User-adjustable pan offset for the controller layout inside the
    /// panel. Lets the user drag the controller around when zoomed in.
    /// Reset to .zero when the user lowers zoom to 0.5 or less.
    @State private var panOffset: CGSize = .zero
    @State private var dragInProgress: CGSize = .zero

    /// Popover state for the on-controller light-bar widget.
    @State private var showLightBarPopover: Bool = false

    /// Transient feedback after the user clicks "Reset gyroscope" in
    /// the Motion popover. Shows for ~1.5s then clears.
    @State private var gyroResetFeedback: String?

    /// Integrated gyro orientation (radians). Owned at this level so the
    /// integrator timer is created exactly ONCE (placing it inside
    /// MotionWidget caused it to be recreated on every 30 Hz render of
    /// the parent TimelineView, which destabilized the subscription and
    /// made the model freeze after the first tick).
    @State private var integratedRoll: Float = 0
    @State private var integratedPitch: Float = 0
    @State private var integratedYaw: Float = 0

    @State private var slotState: Int = 0
    private var slot: Int { fixedSlot ?? slotState }
    /// Per-widget open-popover flags. Keyed by widget label so each widget
    /// owns its own popover anchored at its own bounds (no more popovers
    /// flying to the centre of the screen).
    @State private var openInspectorLabel: String?

    // MARK: - Drag-to-rearrange

    /// True when the user has flipped the visualizer into "Customize layout"
    /// mode. While on, every widget sprouts a dashed yellow outline and can
    /// be dragged around. Clicks open the popover as usual when off.
    @State private var editMode: Bool = false
    /// Per-widget offsets from each widget's structural position. Persisted
    /// to UserDefaults per controller model so each controller remembers its
    /// custom layout independently.
    @State private var dragOffsets: [String: CGSize] = [:]
    /// Live offset while the user is mid-drag, so the widget tracks the
    /// finger before we commit the new persisted offset on drag-end.
    @State private var liveDrag: (label: String, translation: CGSize)?

    /// UserDefaults key for this controller model's saved offsets.
    private var layoutStorageKey: String {
        let category = controllerService.controllerDetails[slot]?.productCategory ?? "Default"
        return "VirtualController.layout.\(category)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                // Make sure the header sits ABOVE the controller panel for
                // hit testing - the TimelineView below re-renders 30 Hz and
                // can cover the button's tap region otherwise.
                .zIndex(2)
                .contentShape(Rectangle())

            // Visualizer panel. The gradient/grid background must follow
            // the actually-rendered (scaled) contents - not the outer
            // frame - or the user sees empty backdrop around shrunk
            // contents, or contents bleed past a too-small backdrop
            // when zoomed in.
            //
            // Order matters: padding → background (sized to padded
            // contents) → scaleEffect (scales background + contents
            // together) → offset (pans the whole thing). The outer
            // .frame just centers the scaled block within the column.
            // CRITICAL: the visualizer's 30 fps clock PAUSES when the
            // controller is idle. An always-on TimelineView re-laid-out the
            // full widget tree 30x/second even for untouched controllers
            // (pinning a core); a pure change-gate was choppy because SwiftUI
            // doesn't invalidate on writes to state the body never reads.
            // This hybrid keeps a real time-driven clock for buttery motion
            // and flips `visualizerIdle` (which the body DOES read, via
            // `paused:`) after ~0.7 s without a visible state change.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: visualizerIdle || info == nil)) { _ in
                visualizerPanelContent
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            // The fixed viewport box. Sits on the outer frame so it never scales
            // with the zoom, giving the map a stationary container.
            .background(visualizerBoxBackground)
            // Hard-clip the map to that box. The zoom uses .scaleEffect, a
            // render-only transform that does NOT shrink the view's layout
            // footprint, so a zoomed-in map paints past its bounds and, without
            // this, spills over the sidebar, header, and rows out onto the window.
            // .clipped() is unreliable here: its rectangular clip can fail to mask
            // a child .scaleEffect layer, which composites outside it. An explicit
            // .clipShape forces a real mask layer the scaled content must render
            // into, so every pixel stays inside the box.
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main,
                                     in: .common).autoconnect()) { _ in
                guard info != nil else { return }
                let sig = Self.renderSignature(state)
                if sig != lastRenderSignature {
                    lastRenderSignature = sig
                    lastSignatureChangeAt = CACurrentMediaTime()
                    if visualizerIdle { visualizerIdle = false }
                } else if !visualizerIdle,
                          CACurrentMediaTime() - lastSignatureChangeAt > 0.7 {
                    visualizerIdle = true
                }
            }
            // Drag the panel around when zoomed in past column bounds.
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragInProgress = value.translation
                    }
                    .onEnded { value in
                        panOffset.width += value.translation.width
                        panOffset.height += value.translation.height
                        dragInProgress = .zero
                    }
            )

            if editMode {
                Text("Drag any widget to a new position. The layout saves automatically for this controller model.")
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .padding(.top, 2)
            }
        }
        .onAppear { loadOffsets() }
        .onChange(of: slot) { _, _ in
            loadOffsets()
            // Different controller, different orientation context. Reset
            // so the new controller starts from neutral.
            integratedRoll = 0
            integratedPitch = 0
            integratedYaw = 0
        }
        // Single stable 30 Hz integrator. Reads the latest gyro rates
        // from controllerService.currentStates each tick and accumulates
        // into the @State angle vars - which MotionWidget below reads.
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            let s = state
            let gx = s.motion[.gyroX] ?? 0
            let gy = s.motion[.gyroY] ?? 0
            let gz = s.motion[.gyroZ] ?? 0
            // Idle gate with a NOISE DEADBAND, not an exact-zero test: a real
            // controller's gyro reports tiny nonzero noise on every sample, so
            // == 0 never triggered and the integrator dirtied this whole view
            // 30x/second while two controllers sat untouched (main thread
            // pegged, app-wide lag). Below the deadband there is no visible
            // motion to integrate, so skip the @State writes entirely.
            let deadband: Float = 0.02
            if abs(gx) < deadband && abs(gy) < deadband && abs(gz) < deadband { return }
            let dt: Float = 1.0 / 30.0
            integratedPitch += gx * dt
            integratedYaw   += gy * dt
            integratedRoll  += gz * dt
            integratedPitch = max(-(.pi / 2), min(.pi / 2, integratedPitch))
            integratedYaw   = max(-(.pi / 2), min(.pi / 2, integratedYaw))
            integratedRoll  = max(-(.pi / 2), min(.pi / 2, integratedRoll))
        }
        .debugEditLayout($editMode)
        .debugVizZoom($visualizerScale)
    }

    // MARK: - Header

    private var header: some View {
        // "Live Visualizer" title intentionally omitted - the outer
        // DisclosureGroup in PresetDetailView already labels this section,
        // so repeating it here was redundant.
        HStack(spacing: 10) {
            // Prominent customize toggle. Bordered-prominent + regular
            // control size gives a generous hit region; the smaller
            // .bordered + .small variant was being clipped to a tiny tap
            // target that was hard to hit reliably.
            Button {
                editMode.toggle()
                openInspectorLabel = nil
            } label: {
                Label(editMode ? "Done Editing" : "Edit Layout",
                      systemImage: editMode ? "checkmark.circle.fill" : "pencil.and.outline")
            }
            .buttonStyle(SolidButton(tint: editMode ? .green : .blue, size: .compact))
            .help(editMode ? "Finish customizing" : "Drag widgets to rearrange the layout")
            .spotlightAnchor(SpotlightID.customizeButton)

            if editMode {
                Button {
                    dragOffsets.removeAll()
                    persistOffsets()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.callout)
                }
                .buttonStyle(.solidSecondary)
                .help("Reset all widgets to their default position")
            }

            Spacer()

            // Size slider so the user can shrink or enlarge the controller
            // widgets inside the visualizer (the panel itself stays the
            // same size). Persists per user via @AppStorage. Range 0.3 -
            // 1.5 to match the new wider default zoom-out floor.
            HStack(spacing: 4) {
                Button {
                    visualizerScale = max(0.3, visualizerScale - 0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .help("Shrink visualizer")
                .accessibilityLabel("Shrink visualizer")

                Slider(value: $visualizerScale, in: 0.3...1.5)
                    .frame(width: 80)
                    .help("Resize the live visualizer content")
                    .accessibilityLabel("Visualizer size")
                    .accessibilityValue(String(format: "%.0f percent", visualizerScale * 100))

                Button {
                    visualizerScale = min(1.5, visualizerScale + 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .help("Enlarge visualizer")
                .accessibilityLabel("Enlarge visualizer")
            }

            slotPicker
            statusDot
        }
    }

    /// Always-on light gray grid overlay. The lines are very faint by
    /// default so they read as background texture; in customize mode
    /// they brighten to provide a clear "workbench" feel for the drag
    /// interaction.
    private var gridOverlay: some View {
        Canvas { context, size in
            let minorOpacity: Double = editMode ? 0.18 : 0.06
            let majorOpacity: Double = editMode ? 0.32 : 0.10
            let minor = Color.secondary.opacity(minorOpacity)
            let major = Color.secondary.opacity(majorOpacity)
            let minorStep: CGFloat = 20
            let majorStep: CGFloat = 100

            // Minor grid (faint).
            var minorPath = Path()
            var x: CGFloat = 0
            while x <= size.width {
                minorPath.move(to: CGPoint(x: x, y: 0))
                minorPath.addLine(to: CGPoint(x: x, y: size.height))
                x += minorStep
            }
            var y: CGFloat = 0
            while y <= size.height {
                minorPath.move(to: CGPoint(x: 0, y: y))
                minorPath.addLine(to: CGPoint(x: size.width, y: y))
                y += minorStep
            }
            context.stroke(minorPath, with: .color(minor), lineWidth: 0.5)

            // Major grid (slightly bolder).
            var majorPath = Path()
            x = 0
            while x <= size.width {
                majorPath.move(to: CGPoint(x: x, y: 0))
                majorPath.addLine(to: CGPoint(x: x, y: size.height))
                x += majorStep
            }
            y = 0
            while y <= size.height {
                majorPath.move(to: CGPoint(x: 0, y: y))
                majorPath.addLine(to: CGPoint(x: size.width, y: y))
                y += majorStep
            }
            context.stroke(majorPath, with: .color(major), lineWidth: 1.0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var slotPicker: some View {
        if fixedSlot != nil {
            Text(controllerService.controllerName(at: slot))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            let slots = Array(controllerService.controllerDetails.keys).sorted()
            if slots.count > 1 {
                Picker("Slot", selection: $slotState) {
                    ForEach(slots, id: \.self) { s in
                        Text(controllerService.controllerName(at: s)).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
            } else if let only = slots.first {
                Text(controllerService.controllerName(at: only))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onAppear { slotState = only }
            } else {
                Text("No controller connected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        let connected = controllerService.controllerDetails[slot] != nil
        Group {
            if differentiateWithoutColor {
                // Shape carries the state when color alone is not enough:
                // check for connected, x for disconnected.
                Image(systemName: connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(connected ? Color.green : Color.red.opacity(0.7))
            } else {
                Circle()
                    .fill(connected ? Color.green : Color.red.opacity(0.7))
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Controller connection")
        .accessibilityValue(connected ? "Connected" : "Disconnected")
    }

    // MARK: - Layout

    /// Pauses the visualizer's 30 fps TimelineView when the controller has
    /// shown no visible change for ~0.7 s. Read by the body (via `paused:`)
    /// so transitions re-render correctly.
    @State private var visualizerIdle: Bool = true
    /// Last quantized state fingerprint + when it last moved. Plain change
    /// bookkeeping for the idle detector.
    @State private var lastRenderSignature: Int = 0
    @State private var lastSignatureChangeAt: CFTimeInterval = 0

    private var state: ControllerState {
        controllerService.currentStates[slot] ?? ControllerState()
    }

    /// Order-independent hash of the state with every float snapped to a
    /// 0.02 grid, so sensor noise (gyro jitter, stick drift) below visible
    /// motion does not count as a change.
    private static func renderSignature(_ s: ControllerState) -> Int {
        func q(_ v: Float) -> Int { Int((v * 50).rounded()) }
        var acc = 0
        for (k, v) in s.buttons {
            var h = Hasher(); h.combine(0); h.combine(k); h.combine(q(v))
            acc ^= h.finalize()
        }
        for (k, v) in s.axes {
            var h = Hasher(); h.combine(1); h.combine(k); h.combine(q(v))
            acc ^= h.finalize()
        }
        for (k, v) in s.hats {
            var h = Hasher(); h.combine(2); h.combine(k)
            h.combine(q(v.x)); h.combine(q(v.y))
            acc ^= h.finalize()
        }
        for (k, v) in s.motion {
            // Motion channels get a coarser 0.1 grid: gyro/attitude sensor
            // noise straddles 0.02 bins constantly, which kept the fingerprint
            // flickering and defeated the idle pause whenever a DualSense was
            // connected. Visible rotation easily exceeds 0.1; noise does not.
            var h = Hasher(); h.combine(3); h.combine(k)
            h.combine(Int((v * 10).rounded()))
            acc ^= h.finalize()
        }
        return acc
    }

    private var info: ControllerInfo? {
        controllerService.controllerDetails[slot]
    }

    /// The effective input kind for the slot's visualizer. User-set
    /// `inputKind` on the JoystickMapping takes priority; .auto falls
    /// back to inferring from the binding-type majority.
    private var effectiveInputKind: SlotInputKind {
        let slotJoystick = (slot < preset.joysticks.count)
            ? preset.joysticks[slot] : nil
        guard let j = slotJoystick else { return .controller }
        if j.inputKind != .auto { return j.inputKind }
        guard !j.bindings.isEmpty else { return .controller }
        var counts: [SlotInputKind: Int] = [:]
        for b in j.bindings {
            switch b.input.type {
            case .extKey:
                counts[.keyboard, default: 0] += 1
            case .extMouse:
                counts[.mouse, default: 0] += 1
            case .touchpad, .touchpadRegion, .touchpadGesture:
                counts[.touchpad, default: 0] += 1
            case .midi:
                counts[.midi, default: 0] += 1
            default:
                counts[.controller, default: 0] += 1
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? .controller
    }

    /// The visualizer panel chrome + content, extracted so the live
    /// (TimelineView) and static (no controller) paths render the exact
    /// same thing.
    private var visualizerPanelContent: some View {
        // ONLY the controller map scales and pans. The gradient/grid box used to
        // live inside this scaleEffect, so the box itself grew with the zoom and,
        // past ~1x, its edges scaled clean out of the visible frame - leaving the
        // map with no stationary container and painting out over the sidebar and
        // window. The box is now a FIXED backdrop applied on the outer frame (see
        // body), so it stays put as a viewport and the zoomed map is clipped
        // inside it. Nothing here changes the view's layout footprint, which is
        // what lets that outer clip actually contain the scaled render.
        controllerLayout
            .padding(18)
            .scaleEffect(visualizerScale, anchor: .center)
            .offset(x: panOffset.width + dragInProgress.width,
                    y: panOffset.height + dragInProgress.height)
    }

    /// The stationary gradient + grid + border backdrop the visualizer map sits
    /// inside. It is applied to the outer frame (not the scaled content), so it
    /// never zooms: it is the fixed viewport that bounds the map. The grid reads
    /// as stable workbench paper the controller scales and pans across.
    private var visualizerBoxBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(LinearGradient(
                colors: [Color.secondary.opacity(0.08),
                         Color.secondary.opacity(0.03)],
                startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.18),
                            lineWidth: 0.5)
            )
            .overlay(gridOverlay)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var controllerLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            if onChangeInputKind != nil { templatePicker }
            // Layout choice is driven by the slot's `inputKind` (which the
            // user can set explicitly from the visualizer's template
            // picker OR from the slot's device menu), with a fallback
            // to inferring from binding types. Each widget then gates
            // on (a) hardware capability and (b) binding presence.
            switch effectiveInputKind {
            case .midi:
                MIDIInstrumentView(preset: preset, slot: slot, onJump: onJump)
            case .keyboard:
                keyboardLayout
            case .touchpad:
                touchpadLayout
            case .mouse:
                mouseLayout
            case .controller, .auto:
                if info == nil && !slotHasAnyBinding {
                    emptyVisualizerPlaceholder
                } else {
                    controllerWidgets
                }
            }
        }
    }

    /// Inline picker that lets the user switch THIS visualizer's
    /// template independently of the preset's slot menu. Sets the
    /// joystick mapping's `inputKind` via the host-supplied closure.
    private var templatePicker: some View {
        let currentKind: SlotInputKind = (slot < preset.joysticks.count)
            ? preset.joysticks[slot].inputKind : .auto
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Picker("Template", selection: Binding(
                get: { currentKind },
                set: { newKind in onChangeInputKind?(slot, newKind) }
            )) {
                Label("Auto-detect", systemImage: "wand.and.stars")
                    .tag(SlotInputKind.auto)
                Label { Text("Controller") } icon: { MenuIcon(name: "gamecontroller") }
                    .tag(SlotInputKind.controller)
                Label("Keyboard (macOS)", systemImage: "keyboard")
                    .tag(SlotInputKind.keyboard)
                Label("Touchpad", systemImage: "rectangle.and.hand.point.up.left.fill")
                    .tag(SlotInputKind.touchpad)
                Label("Mouse + Scroll", systemImage: "computermouse")
                    .tag(SlotInputKind.mouse)
                Label("MIDI Instrument", systemImage: "pianokeys")
                    .tag(SlotInputKind.midi)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200, alignment: .leading)
            .accessibilityLabel("Visualizer template")
            .accessibilityHint("Switches the Live Visualizer between controller, keyboard, touchpad, and mouse layouts")
            Spacer(minLength: 0)
            if currentKind != .auto {
                Button("Reset to auto") { onChangeInputKind?(slot, .auto) }
                    .buttonStyle(.solidSecondaryCompact)
                    .controlSize(.small)
                    .help("Use the binding-type majority to pick the template automatically.")
            }
        }
        .padding(.horizontal, 4)
        .spotlightAnchor(SpotlightID.templatePicker)
    }

    // The controller diagram is drawn whenever we are in the controller
    // template: either a physical controller is attached, or the slot has
    // bindings to visualize. Without this, selecting Controller with nothing
    // plugged in rendered a blank panel.
    private var showDiagram: Bool { info != nil || slotHasAnyBinding }

    private var slotHasAnyBinding: Bool {
        guard slot < preset.joysticks.count else { return false }
        return !preset.joysticks[slot].bindings.isEmpty
    }

    @ViewBuilder
    private var emptyVisualizerPlaceholder: some View {
        VStack(spacing: 8) {
            ControllerGlyph(height: 26)
                .foregroundStyle(.tertiary)
            Text("No controller connected for slot \(slot) and no bindings to visualize.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// HID keycodes the slot has at least one binding for. Computed
    /// outside the @ViewBuilder body so the type-checker doesn't have
    /// to thread control flow through the keyboard layout closure.
    private var boundKeyCodesForSlot: Set<Int> {
        guard slot < preset.joysticks.count else { return [] }
        var out: Set<Int> = []
        for b in preset.joysticks[slot].bindings where b.input.type == .extKey {
            out.insert(b.input.index)
        }
        return out
    }

    /// HID keycodes currently held down on any external keyboard.
    /// Walks `rawActiveInputs` (entries like "ekb <code> <dev>") and
    /// pulls the HID code out. O(N) over the active set every render.
    private var pressedKeyCodes: Set<Int> {
        var out: Set<Int> = []
        for entry in ExternalInputDeviceService.shared.rawActiveInputs
            where entry.hasPrefix("ekb ") {
            let parts = entry.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                out.insert(code)
            }
        }
        return out
    }

    /// Set of mouse "kinds" the slot has at least one binding for.
    /// Buttons turn into "btn<N>"; scroll axes into "scrollUp" /
    /// "scrollDown" depending on `axisDirection`; motion axes into
    /// "move". Matches the keys MouseDiagramView highlights.
    private var boundMouseKinds: Set<String> {
        guard slot < preset.joysticks.count else { return [] }
        var out: Set<String> = []
        for b in preset.joysticks[slot].bindings where b.input.type == .extMouse {
            switch b.input.extMouseKind ?? .button {
            case .button:
                out.insert("btn\(b.input.index)")
            case .moveX, .moveY:
                out.insert("move")
            case .scrollX, .scrollY:
                if b.input.axisDirection == .negative {
                    out.insert("scrollDown")
                } else {
                    out.insert("scrollUp")
                }
            case .pressure, .deepPress:
                // Force Touch presses highlight the primary button zone;
                // the diagram has no dedicated pressure pad.
                out.insert("btn0")
            }
        }
        return out
    }

    /// Currently-pressed mouse buttons from `rawActiveInputs`.
    private var pressedMouseButtons: Set<Int> {
        var out: Set<Int> = []
        for entry in ExternalInputDeviceService.shared.rawActiveInputs
            where entry.hasPrefix("ems button ") {
            let parts = entry.split(separator: " ")
            if parts.count >= 3, let n = Int(parts[2]) {
                out.insert(n)
            }
        }
        return out
    }

    /// Keyboard-mode visualizer. Renders the real macOS keyboard layout
    /// (six rows + optional numpad). Bound keys appear in full
    /// contrast; unbound keys dim. Pressed keys flash green.
    @ViewBuilder
    private var keyboardLayout: some View {
        let bound = boundKeyCodesForSlot
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Keyboard layout", systemImage: "keyboard")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(bound.count) key\(bound.count == 1 ? "" : "s") bound")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            KeyboardDiagramView(boundKeyCodes: bound, pressedKeyCodes: pressedKeyCodes)
            if bound.isEmpty {
                Text("No keyboard keys bound for this slot. Scan a key in the editor to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    /// Mouse-mode visualizer. Renders a stylized mouse silhouette
    /// (left / right / middle / wheel + motion ring) plus a legend.
    @ViewBuilder
    private var mouseLayout: some View {
        let boundKinds = boundMouseKinds
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Mouse layout", systemImage: "computermouse")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(boundKinds.count) input\(boundKinds.count == 1 ? "" : "s") bound")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            MouseDiagramView(pressedButtons: pressedMouseButtons,
                             activeKinds: [],
                             boundKinds: boundKinds)
            if boundKinds.isEmpty {
                Text("No mouse inputs bound for this slot. Scan a mouse button or motion / scroll axis in the editor to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    /// Touchpad-template visualizer. Shows the controller's touchpad
    /// surface with user-defined regions overlaid, live finger trails,
    /// the touchpad-button press state, and a binding summary. Sits
    /// between the keyboard and mouse layouts in the template picker
    /// for users who primarily map the touchpad.
    @ViewBuilder
    private var touchpadLayout: some View {
        let touchpadBindings = boundTouchpadInputs
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Touchpad layout", systemImage: "rectangle.and.hand.point.up.left.fill")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(touchpadBindings) input\(touchpadBindings == 1 ? "" : "s") bound")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Reuse the visualizer's existing TouchpadWidget. The
            // widget itself draws at a fixed 220×70 internal size to
            // match its DualSense-touchpad aspect ratio (16:5-ish).
            // Centered in the layout column with a scale-up so it
            // reads as the primary surface of the template rather
            // than a small accessory like it does on the controller
            // layout. Wrapped in a transparent container the same
            // width as the parent so SwiftUI doesn't squeeze it into
            // an awkward leading-aligned chunk.
            HStack {
                Spacer(minLength: 0)
                inspectable(label: "Touchpad", events: [
                    .touchpad(finger: 0, axis: .x, direction: .positive),
                    .touchpad(finger: 0, axis: .y, direction: .positive),
                    .button(13)
                ]) {
                    TouchpadWidget(pressed: (state.buttons[13] ?? 0) > 0.5)
                        .scaleEffect(1.5, anchor: .center)
                        // The scaleEffect leaves the layout box at
                        // the original 220×70 - explicitly pad to
                        // 1.5× so the surrounding HStack measures
                        // the visible size, not the pre-scale size.
                        .padding(.horizontal, 55)
                        .padding(.vertical, 18)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            if touchpadBindings == 0 {
                Text("No touchpad inputs bound for this slot. Scan a finger swipe or a touchpad region in the editor, or pick \"Apply default 1 to 16\" from the Touchpad Setup sheet for a starter grid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    /// Count of touchpad-type bindings on this slot (touchpad axes,
    /// regions, gestures). Drives the "N inputs bound" summary in the
    /// touchpad layout header.
    private var boundTouchpadInputs: Int {
        guard slot < preset.joysticks.count else { return 0 }
        return preset.joysticks[slot].bindings.reduce(0) { acc, b in
            switch b.input.type {
            case .touchpad, .touchpadRegion, .touchpadGesture: return acc + 1
            default: return acc
            }
        }
    }

    @ViewBuilder
    private var controllerWidgets: some View {
        VStack(spacing: 14) {
            // Light-bar strip - rendered for any controller that has one
            // (DualSense, DualShock 4). Sits at the top like the real
            // DualSense light bar that wraps over the touchpad.
            if info?.hasLight == true {
                lightBarStripWidget
            }

            // Top row: bumpers + triggers. v1.1 behavior: always shown
            // when a controller is connected, regardless of which inputs
            // the preset currently binds. The visualizer is a HARDWARE
            // mirror first, binding inspector second; hiding unbound
            // widgets made connected controllers look broken when a
            // preset only mapped a few inputs.
            if showDiagram {
                HStack(alignment: .center, spacing: 16) {
                    VStack(spacing: 8) {
                        inspectable(label: "LT", events: [.axis(4, direction: .positive)]) {
                            TriggerWidget(label: "LT", value: state.axes[4] ?? 0,
                                          threshold: thresholdForAxis(4, dir: .positive),
                                          tint: .blue)
                        }
                        inspectable(label: "LB", events: [.button(4)]) {
                            ShoulderWidget(label: "LB", pressed: (state.buttons[4] ?? 0) > 0.5)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            menuPill(label: "Share", index: 8)
                            menuPill(label: "Home", index: 10)
                            menuPill(label: "Menu", index: 9)
                        }
                        motionWidgetIfAvailable
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 8) {
                        inspectable(label: "RT", events: [.axis(5, direction: .positive)]) {
                            TriggerWidget(label: "RT", value: state.axes[5] ?? 0,
                                          threshold: thresholdForAxis(5, dir: .positive),
                                          tint: .red)
                        }
                        inspectable(label: "RB", events: [.button(5)]) {
                            ShoulderWidget(label: "RB", pressed: (state.buttons[5] ?? 0) > 0.5)
                        }
                    }
                }
            }

            // Middle row: D-pad + all four face buttons. Always shown
            // when a controller is connected; press state lights the
            // glyph regardless of whether a binding exists.
            if showDiagram {
                HStack(alignment: .center) {
                    inspectable(label: "D-pad", events: [
                        .hat(0, direction: .up), .hat(0, direction: .right),
                        .hat(0, direction: .down), .hat(0, direction: .left)
                    ]) {
                        DPadWidget(hat: state.hats[0] ?? (0, 0))
                    }
                    Spacer(minLength: 0)
                    ZStack {
                        faceButton(label: "Y", index: 3, tint: .yellow).offset(y: -22)
                        faceButton(label: "A", index: 0, tint: .green).offset(y: 22)
                        faceButton(label: "X", index: 2, tint: .blue).offset(x: -22)
                        faceButton(label: "B", index: 1, tint: .red).offset(x: 22)
                    }
                    .frame(width: 88, height: 88)
                }
            }

            // Sticks row - both sticks always shown when a controller
            // is connected, even if no binding currently uses them.
            if showDiagram {
                HStack(spacing: 18) {
                    inspectable(label: "Left stick", events: [
                        .axis(0, direction: .positive), .axis(0, direction: .negative),
                        .axis(1, direction: .positive), .axis(1, direction: .negative),
                        .button(11)
                    ]) {
                        StickWidget(label: "Left stick",
                                    x: state.axes[0] ?? 0,
                                    y: state.axes[1] ?? 0,
                                    pressed: (state.buttons[11] ?? 0) > 0.5)
                    }
                    inspectable(label: "Right stick", events: [
                        .axis(2, direction: .positive), .axis(2, direction: .negative),
                        .axis(3, direction: .positive), .axis(3, direction: .negative),
                        .button(12)
                    ]) {
                        StickWidget(label: "Right stick",
                                    x: state.axes[2] ?? 0,
                                    y: state.axes[3] ?? 0,
                                    pressed: (state.buttons[12] ?? 0) > 0.5)
                    }
                }
            }

            // Touchpad - shown whenever the hardware has one, no
            // binding required. The widget reads from TouchpadService's
            // currentF0 / currentF1, which is now fed by either the
            // helper subprocess (older macOS) OR the GameController
            // framework's touchpadPrimary / touchpadSecondary (macOS 14+).
            if info?.hasTouchpad == true {
                inspectable(label: "Touchpad", events: [
                    .touchpad(finger: 0, axis: .x, direction: .positive),
                    .touchpad(finger: 0, axis: .y, direction: .positive),
                    .button(13)
                ]) {
                    TouchpadWidget(pressed: (state.buttons[13] ?? 0) > 0.5)
                }
            }

            // Extra / unknown buttons row - shown when the controller
            // exposes any non-standard physical buttons. Pulls from the
            // service's authoritative snapshot which now includes
            // KVC-discovered DualSense / DualSense Edge buttons (mute,
            // paddles, FN) the typed Apple API doesn't expose, plus
            // every state.buttons[N>12] entry for raw HID gamepads
            // (fight stick macro buttons, arcade pad spares, etc.).
            let extras = controllerService.extraButtonsSnapshot(for: slot)
                .filter { ![13].contains($0.index) }  // Touchpad has its own widget
            if !extras.isEmpty {
                extraButtonsWidget(extras: extras)
            }

            // Extra axes row - controllers with sliders, dials, or
            // extra trigger surfaces past the standard LT/RT (axes 4
            // and 5) get a slim live-value bar per axis.
            let extraAxes = controllerService.extraAxesSnapshot(for: slot)
            if !extraAxes.isEmpty {
                extraAxesWidget(axes: extraAxes)
            }
        }
    }

    @ViewBuilder
    private func extraAxesWidget(axes: [GameControllerService.ExtraAxis]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra axes")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(axes) { axis in
                HStack(spacing: 8) {
                    Text(axis.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    GeometryReader { proxy in
                        let mid = proxy.size.width / 2
                        let normalized = max(-1, min(1, CGFloat(axis.value)))
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green)
                                .frame(width: abs(normalized) * mid, height: 4)
                                .offset(x: normalized >= 0 ? mid : mid + normalized * mid)
                        }
                    }
                    .frame(height: 8)
                    Text(String(format: "%+.2f", axis.value))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(axis.label)
                .accessibilityValue(String(format: "%+.2f", axis.value))
            }
        }
        .padding(.top, 4)
    }

    /// True when the extra button has a real, human-meaningful name
    /// (PS, Home, Mute, paddles, FN). False when it's a raw HID
    /// gamepad's "Button N" / "Btn N" fallback label - those become
    /// round placeholder icons instead.
    private func isNamedExtra(_ label: String) -> Bool {
        let lower = label.lowercased()
        if lower.hasPrefix("button ") { return false }
        if lower.hasPrefix("btn ") { return false }
        return true
    }

    /// Spoken value for the combined "Extra buttons" element. Lists each
    /// named button and appends "pressed" to the ones currently held, so
    /// the state is conveyed without relying on the chip's color.
    private func namedExtrasAccessibilityValue(
        _ extras: [GameControllerService.ExtraButton]
    ) -> String {
        extras.map { extra in
            extra.pressed ? "\(extra.label) pressed" : extra.label
        }.joined(separator: ", ")
    }

    @ViewBuilder
    private func extraButtonsWidget(extras: [GameControllerService.ExtraButton]) -> some View {
        // Detected extras come in two flavours:
        //   - Named (PS, Home, Mute, Left Paddle, FN 1, etc.) - chips
        //     with their proper label.
        //   - Unknown (raw HID gamepads' "Button 14" fallback) - round
        //     placeholder icons the user can drag around in edit mode.
        // Each subgroup only renders when its list is non-empty, so a
        // controller with only named extras never shows the "Unknown
        // buttons" header and vice versa.
        let named = extras.filter { isNamedExtra($0.label) }
        let unknown = extras.filter { !isNamedExtra($0.label) }
        VStack(alignment: .leading, spacing: 8) {
            if !named.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra buttons")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    FlowChipRow(chips: named.map { extra in
                        let color: Color = extra.pressed ? .green : .secondary
                        return (extra.label, color)
                    })
                    // FlowChipRow encodes each chip's press state only as a
                    // color, which VoiceOver cannot perceive. Collapse the
                    // row into one element that names each button and speaks
                    // which are currently pressed as a non-color cue.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Extra buttons")
                    .accessibilityValue(namedExtrasAccessibilityValue(named))
                }
            }
            if !unknown.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unknown buttons")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        ForEach(unknown) { btn in
                            unknownButtonPlaceholder(btn)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    /// Round placeholder icon for an unknown extra button. Shows the
    /// raw index in the centre, flashes green while the button is held,
    /// and participates in the visualizer's "Customize layout" drag
    /// machinery via `inspectable()` so the user can reposition it.
    @ViewBuilder
    private func unknownButtonPlaceholder(
        _ button: GameControllerService.ExtraButton
    ) -> some View {
        inspectable(label: "extra-\(button.index)", events: []) {
            ZStack {
                Circle()
                    .fill(button.pressed
                          ? Color.green.opacity(0.85)
                          : Color.secondary.opacity(0.18))
                Circle()
                    .stroke(button.pressed
                            ? Color.green
                            : Color.secondary.opacity(0.4),
                            lineWidth: 1)
                Text("\(button.index)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(button.pressed ? .white : .primary)
            }
            .frame(width: 28, height: 28)
            .help("Unknown extra button \(button.index) - drag in 'Customize layout' to reposition")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Extra button \(button.index)")
            .accessibilityValue(button.pressed ? "pressed" : "released")
        }
    }

    /// Clickable light-bar strip that mimics the real DualSense's top
    /// LED bar. Filled with the preset's chosen color when set, or a
    /// faint shimmering "click to set" placeholder otherwise. Tap to open
    /// the per-preset Light Bar editor in a popover anchored right here.
    @ViewBuilder
    private var lightBarStripWidget: some View {
        // The light-bar color is applied at engine-start time, so editing
        // it while the engine is running cannot change what the controller
        // is currently showing. Gate the popover behind "engine stopped"
        // so the UI doesn't mislead - the user has to stop the engine
        // first, change the color, then start again.
        let locked = mappingEngine.isRunning
        return Button {
            guard !locked else { return }
            showLightBarPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: locked
                      ? "light.beacon.max.fill"
                      : "light.beacon.max.fill")
                    .font(.caption2)
                    .foregroundStyle(lightBarTint ?? .secondary)
                    .opacity(lightBarTint == nil ? 0.4 : 1)

                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                    if let tint = lightBarTint {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(
                                colors: [tint.opacity(0.85), tint, tint.opacity(0.85)],
                                startPoint: .leading, endPoint: .trailing))
                            .shadow(color: tint.opacity(0.7), radius: 5)
                    } else {
                        Text(locked
                             ? "Stop engine to edit color"
                             : "Click to set color")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 220, maxHeight: 8)
                .clipShape(RoundedRectangle(cornerRadius: 3))

                Image(systemName: locked ? "lock.fill" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(lightBarTint?.opacity(0.55) ?? Color.secondary.opacity(0.2),
                            lineWidth: 0.75)
            )
            .opacity(locked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(locked
              ? "Stop the engine first - the light-bar color is applied when the engine starts"
              : (lightBarTint == nil
                 ? "Pick a light-bar color for this preset"
                 : "Edit this preset's light-bar color"))
        .spotlightAnchor(SpotlightID.lightBarStrip)
        .popover(isPresented: $showLightBarPopover, arrowEdge: .top) {
            trailing()
                .padding(4)
        }
        .onChange(of: mappingEngine.isRunning) { _, running in
            // If the user starts the engine while the popover is open,
            // close it - any edits would silently no-op until restart.
            if running { showLightBarPopover = false }
        }
    }

    @ViewBuilder
    private var motionWidgetIfAvailable: some View {
        if info?.supportsMotion == true {
            inspectable(label: "Motion", events: [
                .motion(.gyroY, direction: .positive),
                .motion(.gyroX, direction: .positive)
            ]) {
                MotionWidget(
                    state: state,
                    integratedRoll: integratedRoll,
                    integratedPitch: integratedPitch,
                    integratedYaw: integratedYaw
                )
            }
        }
    }

    /// Wraps any widget in a Button whose popover anchors at the widget's
    /// own bounds - so taps open a popover *right there* instead of
    /// floating to the middle of the window. In edit mode the widget
    /// instead participates in drag-to-rearrange: each widget remembers an
    /// (x, y) offset from its structural position and applies it here.
    @ViewBuilder
    private func inspectable<Content: View>(
        label: String, events: [InputEvent],
        @ViewBuilder content: () -> Content
    ) -> some View {
        let persistedOffset = dragOffsets[label] ?? .zero
        let liveOffset: CGSize = (liveDrag?.label == label) ? liveDrag!.translation : .zero
        let totalOffset = CGSize(
            width: persistedOffset.width + liveOffset.width,
            height: persistedOffset.height + liveOffset.height
        )

        if editMode {
            content()
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            Color.yellow.opacity(0.75),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                        .padding(-2)
                        .allowsHitTesting(false)
                )
                .offset(totalOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            liveDrag = (label, value.translation)
                        }
                        .onEnded { value in
                            let base = dragOffsets[label] ?? .zero
                            dragOffsets[label] = CGSize(
                                width: base.width + value.translation.width,
                                height: base.height + value.translation.height
                            )
                            liveDrag = nil
                            persistOffsets()
                        }
                )
        } else {
            let isOpen = Binding(
                get: { openInspectorLabel == label },
                set: { value in openInspectorLabel = value ? label : nil }
            )
            Button {
                openInspectorLabel = label
            } label: {
                content()
            }
            .buttonStyle(.plain)
            .offset(totalOffset)
            // Fold the widget's own accessibility element (label + live
            // value) up onto the tappable button, and add a hint so
            // VoiceOver users know activating it inspects the bindings.
            .accessibilityElement(children: .combine)
            .accessibilityHint("Inspects bindings for this input")
            .popover(isPresented: isOpen, arrowEdge: .top) {
                inspectorContent(label: label, events: events)
            }
        }
    }

    // MARK: - Layout persistence

    /// Reload saved offsets for the currently-selected controller model.
    /// Called on appear and whenever the slot changes.
    private func loadOffsets() {
        guard let raw = UserDefaults.standard.dictionary(forKey: layoutStorageKey)
                as? [String: [String: Double]] else {
            dragOffsets = [:]
            return
        }
        dragOffsets = raw.compactMapValues { dict in
            guard let w = dict["w"], let h = dict["h"] else { return nil }
            return CGSize(width: w, height: h)
        }
    }

    /// Persist the current offsets dictionary for the active controller
    /// model. UserDefaults can't store CGSize directly so we encode each
    /// entry as ["w": width, "h": height].
    private func persistOffsets() {
        let encoded = dragOffsets.mapValues { ["w": Double($0.width),
                                               "h": Double($0.height)] }
        UserDefaults.standard.set(encoded, forKey: layoutStorageKey)
    }

    /// Single face button with its own anchored popover.
    private func faceButton(label: String, index: Int, tint: Color) -> some View {
        inspectable(label: label, events: [.button(index)]) {
            FaceButtonGlyph(label: label,
                            pressed: (state.buttons[index] ?? 0) > 0.5,
                            tint: tint)
        }
    }

    /// One menu pill (Share / Home / Menu) wrapped in inspectable.
    private func menuPill(label: String, index: Int) -> some View {
        let pressed = (state.buttons[index] ?? 0) > 0.5
        return inspectable(label: label, events: [.button(index)]) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(pressed ? .green : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(pressed ? Color.green.opacity(0.20) : Color.secondary.opacity(0.10))
                )
                .overlay(Capsule().stroke(pressed ? Color.green : Color.secondary.opacity(0.3), lineWidth: 0.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label) button")
                .accessibilityValue(pressed ? "pressed" : "released")
        }
    }

    // MARK: - Inspector (dead helper kept for symmetry - per-widget
    // popovers anchor themselves via inspectable() instead).

    /// A binding match enriched with the joystick group it lives in and its
    /// 1-based position within that group, so the popover can show "#3" next
    /// to each row and jump back to the exact same row in the editor.
    fileprivate struct BindingMatch: Identifiable {
        let id: UUID
        let binding: BindingModel
        let joystickIndex: Int
        let displayNumber: Int
    }

    /// Locate every binding across every joystick group whose input matches
    /// one of the widget's events. Built outside of ViewBuilder because for
    /// loops aren't allowed in result builders.
    private func matches(for events: [InputEvent]) -> [BindingMatch] {
        let serializedSet = Set(events.map(\.serialized))
        var collected: [BindingMatch] = []
        for (joystickIndex, group) in preset.joysticks.enumerated() {
            for (bindIndex, binding) in group.bindings.enumerated()
                where serializedSet.contains(binding.input.serialized) {
                collected.append(BindingMatch(
                    id: binding.id,
                    binding: binding,
                    joystickIndex: joystickIndex,
                    displayNumber: bindIndex + 1
                ))
            }
        }
        return collected
    }

    /// Popover content for an inspectable widget. Each binding row is its
    /// own button so the user can tap the description to jump straight to
    /// the editor; nothing requires hitting a tiny Edit button.
    @ViewBuilder
    fileprivate func inspectorContent(label: String, events: [InputEvent]) -> some View {
        let matchingBindings = matches(for: events)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.headline)
                Spacer()
                if !matchingBindings.isEmpty {
                    Text("\(matchingBindings.count) bound")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Motion widget gets an extra "Reset gyroscope" action so
            // the user can re-zero on a flat surface without leaving
            // the visualizer. The action samples the controller's
            // current motion reading and saves it as the new drift
            // baseline (same call site as the PresetEditor toolbar
            // button).
            if label == "Motion" {
                gyroResetActionRow
                Divider()
            }
            if matchingBindings.isEmpty {
                Text("No bindings in this preset target this input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let first = events.first {
                    Button {
                        openInspectorLabel = nil
                        onJump?(EditorJumpTarget(
                            joystickIndex: slot,
                            inputSerialized: first.serialized
                        ))
                    } label: {
                        Label("Open editor anyway", systemImage: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .help("Open the preset editor for this preset")
                }
            } else {
                ForEach(matchingBindings) { match in
                    Button {
                        openInspectorLabel = nil
                        onJump?(EditorJumpTarget(
                            joystickIndex: match.joystickIndex,
                            inputSerialized: match.binding.input.serialized
                        ))
                    } label: {
                        HStack(spacing: 8) {
                            Text("#\(match.displayNumber)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.secondary.opacity(0.18))
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.binding.input.displayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                ForEach(match.binding.outputs) { out in
                                    Text(out.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if preset.joysticks.count > 1 {
                                    Text("Input Device \(match.joystickIndex)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.08))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to row #\(match.displayNumber) in the editor")
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - Motion popover extras

    /// Tiny row injected at the top of the Motion popover with a
    /// "Reset gyroscope" button. Mirrors the toolbar quick-zero in
    /// PresetEditor so the user can re-zero without leaving the
    /// visualizer.
    @ViewBuilder
    private var gyroResetActionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                resetGyroFromVisualizer()
            } label: {
                Label("Reset gyroscope (re-zero now)", systemImage: "scope")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.solidCompact)
            .help("Sample the controller's current motion as the new resting baseline. Hold the controller flat and steady, then click.")

            if let msg = gyroResetFeedback {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
    }

    /// Sample the current motion reading off every connected
    /// motion-capable controller and save it as the new drift
    /// baseline. Same algorithm as PresetEditorView.quickZeroGyro;
    /// reproduced here so the visualizer popover doesn't need to
    /// reach into the editor view's private state.
    private func resetGyroFromVisualizer() {
        var count = 0
        for controller in controllerService.connectedControllers {
            guard let motion = controller.motion else { continue }
            let key = MotionCalibrationService.identityKey(for: controller)
            MotionCalibrationService.shared.quickZero(
                forKey: key,
                gyroX: Float(motion.rotationRate.x),
                gyroY: Float(motion.rotationRate.y),
                gyroZ: Float(motion.rotationRate.z),
                accelX: Float(motion.userAcceleration.x),
                accelY: Float(motion.userAcceleration.y),
                accelZ: Float(motion.userAcceleration.z)
            )
            count += 1
        }
        // Reset the parent's integrated angles too so the on-screen
        // model immediately snaps back to centre instead of slowly
        // drifting away from whatever orientation it was showing.
        integratedRoll = 0
        integratedPitch = 0
        integratedYaw = 0
        withAnimation(.easeInOut(duration: 0.18)) {
            gyroResetFeedback = count == 0
                ? "No motion-capable controller connected"
                : "Zeroed on \(count) controller\(count == 1 ? "" : "s")"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.18)) {
                gyroResetFeedback = nil
            }
        }
    }

    // MARK: - Thresholds

    /// Return the deadzone of the first binding that uses this axis half,
    /// for display as a marker on the trigger widget. Falls back to 0.25.
    private func thresholdForAxis(_ index: Int, dir: AxisDirection) -> Float {
        for joystick in preset.joysticks {
            for binding in joystick.bindings
                where binding.input.type == .axis
                    && binding.input.index == index
                    && binding.input.axisDirection == dir {
                return binding.deadzone ?? 0.25
            }
        }
        return 0.25
    }
}

// MARK: - Widget components

private struct StickWidget: View {
    let label: String
    let x: Float
    let y: Float
    let pressed: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(pressed ? Color.green.opacity(0.25) : Color.secondary.opacity(0.18))
                Circle()
                    .stroke(pressed ? Color.green : Color.secondary.opacity(0.4), lineWidth: 1.5)
                // Crosshair
                Path { p in
                    p.move(to: CGPoint(x: 36, y: 0)); p.addLine(to: CGPoint(x: 36, y: 72))
                    p.move(to: CGPoint(x: 0, y: 36)); p.addLine(to: CGPoint(x: 72, y: 36))
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                // Thumb dot
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .offset(x: CGFloat(x) * 26, y: CGFloat(y) * 26)
                    .animation(.linear(duration: 0.03), value: x)
                    .animation(.linear(duration: 0.03), value: y)
            }
            .frame(width: 72, height: 72)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    /// Spoken description of the live analog position and press state, so
    /// VoiceOver users hear where the stick is instead of a silent circle.
    private var accessibilityValue: String {
        let xPart = String(format: "X %.2f", x)
        let yPart = String(format: "Y %.2f", y)
        let pressPart = pressed ? ", pressed" : ""
        return "\(xPart), \(yPart)\(pressPart)"
    }
}

private struct TriggerWidget: View {
    let label: String
    let value: Float
    let threshold: Float
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 22, height: 80)
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.gradient)
                    .frame(width: 22, height: max(2, CGFloat(value) * 80))
                    .animation(.linear(duration: 0.04), value: value)
                // Threshold marker
                Rectangle()
                    .fill(Color.orange.opacity(0.7))
                    .frame(width: 30, height: 1)
                    .offset(y: -CGFloat(threshold) * 80)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", min(1, max(0, value)) * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) trigger")
        .accessibilityValue(String(format: "%.0f percent", min(1, max(0, value)) * 100))
    }
}

private struct ShoulderWidget: View {
    let label: String
    let pressed: Bool

    var body: some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.green.opacity(0.25) : Color.secondary.opacity(0.15))
            Capsule()
                .stroke(pressed ? Color.green : Color.secondary.opacity(0.35), lineWidth: 1)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(pressed ? .green : .secondary)
        }
        .frame(width: 56, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) shoulder")
        .accessibilityValue(pressed ? "pressed" : "released")
    }
}

private struct DPadWidget: View {
    let hat: (x: Float, y: Float)

    var body: some View {
        let up = hat.y > 0.5
        let down = hat.y < -0.5
        let left = hat.x < -0.5
        let right = hat.x > 0.5
        VStack(spacing: 2) {
            arrow(up: true, active: up)
            HStack(spacing: 2) {
                arrow(left: true, active: left)
                Color.clear.frame(width: 20, height: 20)
                arrow(right: true, active: right)
            }
            arrow(down: true, active: down)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("D-pad")
        .accessibilityValue(directionValue(up: up, down: down, left: left, right: right))
    }

    /// Spoken direction the D-pad is currently pressed toward, combining
    /// the two axes so diagonals read naturally (for example "up right").
    private func directionValue(up: Bool, down: Bool, left: Bool, right: Bool) -> String {
        var parts: [String] = []
        if up { parts.append("up") }
        if down { parts.append("down") }
        if left { parts.append("left") }
        if right { parts.append("right") }
        return parts.isEmpty ? "centered" : parts.joined(separator: " ")
    }

    private func arrow(up: Bool = false, down: Bool = false, left: Bool = false, right: Bool = false, active: Bool) -> some View {
        let icon: String =
            up ? "arrowtriangle.up.fill" :
            down ? "arrowtriangle.down.fill" :
            left ? "arrowtriangle.left.fill" :
            "arrowtriangle.right.fill"
        return Image(systemName: icon)
            .font(.body)
            .foregroundStyle(active ? Color.green : Color.secondary.opacity(0.55))
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Color.green.opacity(0.18) : Color.secondary.opacity(0.10))
            )
    }
}

private struct FaceButtonGlyph: View {
    let label: String
    let pressed: Bool
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(pressed ? tint.opacity(0.4) : Color.secondary.opacity(0.18))
            Circle()
                .stroke(pressed ? tint : Color.secondary.opacity(0.35), lineWidth: 1.5)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(pressed ? tint : Color.secondary)
        }
        .frame(width: 28, height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) button")
        .accessibilityValue(pressed ? "pressed" : "released")
    }
}

private struct TouchpadWidget: View {
    /// Touchpad button (index 13) state. When the user physically pushes
    /// the touchpad down (not just touches it), this flips to true and the
    /// widget glows green to signal a click vs a swipe.
    let pressed: Bool

    /// Single sample of a finger's position with the timestamp it was
    /// captured. The view ages each point and uses age to compute opacity
    /// + size, producing the "whoosh" trail behind the moving finger.
    private struct TrailPoint: Identifiable {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let time: Date
    }

    @State private var trailF0: [TrailPoint] = []
    @State private var trailF1: [TrailPoint] = []

    /// How long a trail point lingers before fading away. Short enough to
    /// feel responsive, long enough that a fast swipe leaves a visible arc.
    private let trailDuration: TimeInterval = 0.35
    /// Hard cap on how many trail samples we retain per finger. Even at a
    /// short trailDuration the sample timer can overrun this on rapid
    /// motion; the cap keeps per-frame render cost bounded. 24 still
    /// produces a visually continuous arc on a fast swipe.
    private let maxTrailPoints = 24
    /// Width / height of the rendered touchpad rect.
    private let pad = CGSize(width: 220, height: 70)
    /// Sampled-coordinate range (matches the helper subprocess output).
    private let coordScale = CGSize(width: 1920, height: 1080)

    /// Snapshot of the user-defined detection regions (from the
    /// Touchpad Calibration sheet) so the visualizer can overlay
    /// them. We refresh this on every render tick along with the
    /// trail samples - cheap because the region list is short and
    /// allRegions() just snapshots an Array under the service lock.
    @State private var regions: [TouchpadRegion] = []
    /// IDs of regions currently being touched, so we can light them
    /// up the same way TouchpadCalibrationView does.
    @State private var pressedRegionIDs: Set<UUID> = []

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(pressed
                      ? Color.green.opacity(0.35)
                      : Color.black.opacity(0.25))
                .animation(.easeOut(duration: 0.12), value: pressed)
            RoundedRectangle(cornerRadius: 8)
                .stroke(pressed ? Color.green : Color.mint.opacity(0.5),
                        lineWidth: pressed ? 2 : 1)
                .shadow(color: pressed ? Color.green.opacity(0.7) : .clear,
                        radius: pressed ? 10 : 0)
                .animation(.easeOut(duration: 0.12), value: pressed)

            // Faint grid so the surface reads as a real touchpad.
            Path { p in
                p.move(to: CGPoint(x: pad.width / 2, y: 6))
                p.addLine(to: CGPoint(x: pad.width / 2, y: pad.height - 6))
                p.move(to: CGPoint(x: 12, y: pad.height / 2))
                p.addLine(to: CGPoint(x: pad.width - 12, y: pad.height / 2))
            }
            .stroke(Color.mint.opacity(0.15), lineWidth: 0.5)

            // Detection regions overlay. The visualizer is the same
            // surface the user defined regions on in
            // TouchpadCalibrationView, so we mirror that view's region
            // rendering 1:1 (palette colour, fill/stroke, "lit up when
            // pressed" highlight). Always rendered behind the finger
            // trails so a region's colour shows through.
            ForEach(regions) { region in
                regionRect(region)
            }

            // Trails: rendered through a single Canvas (one draw call
            // for all points per finger) instead of dozens of SwiftUI
            // Circle views with expensive .blur modifiers. This was the
            // root cause of the visible choppiness - the previous
            // approach created up to 132 blurred-circle subviews per
            // frame and the offscreen blur passes were saturating the
            // GPU. Canvas draws everything in one pass with native
            // CoreGraphics fills.
            trailCanvas

            // Dot for the most recent position. Kept as a regular view
            // (only 2 of them) so we get the natural shadow + crispness
            // of SwiftUI shape rendering for the focal point.
            dotRender(point: trailF0.last, hue: .mint, base: 12)
            dotRender(point: trailF1.last, hue: .cyan, base: 10)

            Text("Touchpad")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .position(x: 32, y: 8)
        }
        .frame(width: pad.width, height: pad.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touchpad")
        .accessibilityValue(pressed ? "pressed" : "released")
        // 60 Hz sampling. Higher rates produced visibly worse
        // performance because each tick invalidated @State and forced
        // SwiftUI to rebuild the whole widget body. 60 Hz matches the
        // typical display refresh rate, and the data source itself is
        // event-driven (valueChangedHandler fires on every controller
        // HID report) so the last sampled position is always fresh.
        .onReceive(Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()) { now in
            sampleAndPrune(now: now)
            refreshRegionState()
        }
        // Retain the TouchpadHelper subprocess while the widget is on
        // screen so finger positions flow into the visualizer regardless
        // of whether a touchpad-using preset is active. MappingEngine
        // separately retains it when needed; the ref-count keeps things
        // tidy when both want it running.
        .onAppear {
            TouchpadService.shared.retain()
            regions = TouchpadService.shared.allRegions()
        }
        .onDisappear { TouchpadService.shared.release() }
    }

    /// Per-region rect overlay. Same coordinate space as the trail
    /// rendering: normalized [0...1] inside the pad rectangle.
    @ViewBuilder
    private func regionRect(_ region: TouchpadRegion) -> some View {
        let isPressed = pressedRegionIDs.contains(region.id)
        let color = paletteColor(at: region.colorIndex)
        let rect = CGRect(
            x: CGFloat(region.minX) * pad.width,
            y: CGFloat(region.minY) * pad.height,
            width: CGFloat(region.maxX - region.minX) * pad.width,
            height: CGFloat(region.maxY - region.minY) * pad.height)
        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(isPressed ? 0.6 : 0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(isPressed ? 1 : 0.55),
                            lineWidth: isPressed ? 1.5 : 0.75)
            )
            .frame(width: max(2, rect.width), height: max(2, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    /// Pull the current region list + pressed set out of the service.
    /// Single lock acquisition via `snapshotRegions()` (was 1 + N locks
    /// before, one per region for isRegionPressed). At 60 Hz with ~10
    /// regions this used to do ~600 NSLock ops/sec; now it's 60.
    private func refreshRegionState() {
        let (snapshot, pressed) = TouchpadService.shared.snapshotRegions()
        if snapshot.map(\.id) != regions.map(\.id) {
            regions = snapshot
        }
        if pressed != pressedRegionIDs {
            pressedRegionIDs = pressed
        }
    }

    /// Mirror of TouchpadCalibrationView.paletteColor so the visualizer
    /// renders each region in the same colour the user picked in the
    /// calibration sheet. Duplicated rather than shared because both
    /// views use a static palette; the entries never change.
    private func paletteColor(at index: Int) -> Color {
        let palette = TouchpadRegion.colorPalette
        let safeIndex = max(0, min(palette.count - 1, index))
        switch palette[safeIndex] {
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green":  return .green
        case "mint":   return .mint
        case "teal":   return .teal
        case "cyan":   return .cyan
        case "blue":   return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink":   return .pink
        case "brown":  return .brown
        default:       return .gray
        }
    }

    /// Single-pass Canvas that renders both fingers' trails as plain
    /// fills. Replaces the previous ForEach-of-blurred-Circles approach
    /// which was the main source of touchpad lag (blur is implemented
    /// as an offscreen pass per view; ~130 of those per frame swamped
    /// the GPU).
    private var trailCanvas: some View {
        // Pause the 60 Hz clock when there is nothing to animate. With both
        // trail buffers empty the Canvas was repainting an empty pad 60x/sec
        // for the whole time a touchpad controller is connected. A finger-down
        // appends to trailF0/trailF1 (@State), which re-runs body and resumes
        // this same-identity timeline on the same render pass (no added latency).
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: trailF0.isEmpty && trailF1.isEmpty)) { context in
            Canvas { ctx, _ in
                drawTrail(into: ctx, points: trailF0,
                          color: .mint, at: context.date)
                drawTrail(into: ctx, points: trailF1,
                          color: .cyan, at: context.date)
            }
        }
        .frame(width: pad.width, height: pad.height)
        .allowsHitTesting(false)
    }

    /// Helper that draws one finger's trail into the Canvas context.
    /// Older points are smaller and more transparent than newer ones,
    /// matching the original look but without the expensive per-point
    /// blur. Kept as a static-ish function so the closure stays simple
    /// and the SwiftUI type-checker doesn't time out on a complex body.
    private func drawTrail(into ctx: GraphicsContext, points: [TrailPoint],
                           color: Color, at now: Date) {
        for p in points {
            let age = now.timeIntervalSince(p.time)
            let factor = max(0, 1 - age / trailDuration)
            guard factor > 0.02 else { continue }
            let radius = (4 + 8 * factor) / 2
            let x = p.x / coordScale.width * pad.width
            let y = p.y / coordScale.height * pad.height
            let rect = CGRect(x: x - radius, y: y - radius,
                              width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color(color.opacity(0.45 * factor)))
        }
    }

    /// Solid "current finger" dot rendered on top of the trail so the
    /// active position pops out from the fading wash behind it.
    @ViewBuilder
    private func dotRender(point: TrailPoint?, hue: Color, base: CGFloat) -> some View {
        if let p = point {
            Circle()
                .fill(hue)
                .frame(width: base, height: base)
                .shadow(color: hue.opacity(0.7), radius: 4)
                .position(x: p.x / coordScale.width * pad.width,
                          y: p.y / coordScale.height * pad.height)
        }
    }

    /// Append the current finger positions to the trail buffers (if a
    /// finger is down) and drop any samples older than `trailDuration`.
    /// Also enforces `maxTrailPoints` so a stuck timer can't grow the
    /// buffer unboundedly between prune sweeps.
    private func sampleAndPrune(now: Date) {
        // Idle gate: with no finger on the pad and no fading trail left to
        // prune, every line below is a no-op - but the array mutations still
        // dirtied @State 60x/second and re-rendered the widget continuously
        // while a touchpad controller was merely connected. Bail out first.
        if TouchpadService.shared.currentPosition(finger: 0) == nil,
           TouchpadService.shared.currentPosition(finger: 1) == nil,
           trailF0.isEmpty, trailF1.isEmpty {
            return
        }
        if let p = TouchpadService.shared.currentPosition(finger: 0) {
            trailF0.append(TrailPoint(x: CGFloat(p.x), y: CGFloat(p.y), time: now))
        }
        if let p = TouchpadService.shared.currentPosition(finger: 1) {
            trailF1.append(TrailPoint(x: CGFloat(p.x), y: CGFloat(p.y), time: now))
        }
        let cutoff = now.addingTimeInterval(-trailDuration)
        trailF0.removeAll { $0.time < cutoff }
        trailF1.removeAll { $0.time < cutoff }
        if trailF0.count > maxTrailPoints {
            trailF0.removeFirst(trailF0.count - maxTrailPoints)
        }
        if trailF1.count > maxTrailPoints {
            trailF1.removeFirst(trailF1.count - maxTrailPoints)
        }
    }
}

private struct MotionWidget: View {
    let state: ControllerState
    /// Integrated angles passed in from the parent (VirtualControllerView)
    /// where the single stable Timer lives. We don't run the integrator
    /// here because this view is recreated on every 30 Hz tick of the
    /// outer TimelineView, which kept tearing down Timer subscriptions
    /// and freezing the model after the first sample.
    let integratedRoll: Float
    let integratedPitch: Float
    let integratedYaw: Float

    var body: some View {
        // Prefer real attitude when the controller reports it; fall back
        // to the parent's integrated gyro angles so the model still shows
        // live motion on controllers where Apple's sensor fusion isn't
        // running.
        let rawRoll  = (state.motion[.rollAngle]  ?? 0) * .pi
        let rawPitch = (state.motion[.pitchAngle] ?? 0) * (.pi / 2)
        let rawYaw   = (state.motion[.yawAngle]   ?? 0) * .pi
        let hasAttitude = abs(rawRoll) + abs(rawPitch) + abs(rawYaw) > 0.0001

        let roll  = hasAttitude ? rawRoll  : integratedRoll
        let pitch = hasAttitude ? rawPitch : integratedPitch
        let yaw   = hasAttitude ? rawYaw   : integratedYaw

        return GyroVisualizationView(
            gyroX: state.motion[.gyroX] ?? 0,
            gyroY: state.motion[.gyroY] ?? 0,
            gyroZ: state.motion[.gyroZ] ?? 0,
            rollAngle: roll,
            pitchAngle: pitch,
            yawAngle: yaw,
            mode: .compact
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Motion")
        .accessibilityValue(String(
            format: "Roll %.0f, pitch %.0f, yaw %.0f degrees",
            roll * 180 / .pi, pitch * 180 / .pi, yaw * 180 / .pi))
    }
}

// MARK: - MIDI Instrument layout

/// The MIDI template for the Live Visualizer: a full instrument panel that
/// renders inside the same box, picker, and zoom chrome as the controller
/// layouts. Selected from the template picker like any other layout and
/// chosen automatically for slots whose bindings are mostly MIDI, so MIDI
/// presets get it by default.
///
/// What it shows, per connected device (or one resting panel with nothing
/// connected):
///
///   • Seven-octave velocity-shaded keyboard - held notes glow with press
///     strength, bound notes carry a dot, octaves are labelled
///   • A dial for every bound CC (at rest until touched) plus every CC the
///     hardware has sent, with standard controller names (Mod Wheel,
///     Cutoff, Sustain...), knob-mode badges, and the freshest knob lit
///   • Pitch bend and aftertouch meters, the last Program Change, and a
///     16-slot channel activity strip
///   • A rolling event log (notes with velocity, sparse CC sweeps, program
///     changes) plus the session's total event count
///
/// Every key and knob opens the binding inspector with jump-to-editor.
/// Render discipline: state only mutates when the service's event counter
/// or device list actually changed, so an idle instrument costs one lock
/// per tick and zero re-renders.
struct MIDIInstrumentView: View {
    let preset: Preset
    let slot: Int
    var onJump: ((EditorJumpTarget) -> Void)?

    @State private var snapshot: [MIDIInputService.DeviceActivity] = []
    @State private var lastCounter: UInt64 = 0
    @State private var deviceSignature: String = ""
    @State private var openInspector: String?
    @State private var stripWidthEstimate: CGFloat = 600

    /// Keyboard strip range: C0...C8, seven octaves.
    private static let lowNote = 24, highNote = 108
    private static let maxKnobs = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.isEmpty {
                devicePanel(placeholderDevice)
            } else {
                ForEach(snapshot) { device in
                    devicePanel(device)
                }
            }
        }
        .onAppear {
            // Live even while the preset is inactive, so the user can watch
            // their gear before flipping the engine on.
            MIDIInputService.shared.start()
            refresh(force: true)
        }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            refresh(force: false)
        }
    }

    private var placeholderDevice: MIDIInputService.DeviceActivity {
        MIDIInputService.DeviceActivity(
            id: "placeholder", name: "MIDI",
            notesDown: [], ccs: [], pitchBend: nil, aftertouch: nil,
            lastProgram: nil, velocities: [:], channelStamps: [:],
            recent: [], eventCount: 0)
    }

    private func refresh(force: Bool) {
        let counter = MIDIInputService.shared.activityCounter()
        let devices = MIDIInputService.shared.connectedDevices()
        let signature = devices.map(\.id).joined(separator: ",")
        guard force || counter != lastCounter || signature != deviceSignature else { return }
        lastCounter = counter
        deviceSignature = signature
        snapshot = MIDIInputService.shared.activitySnapshot()
    }

    /// Standard General MIDI controller names for the knob labels.
    static func ccName(_ cc: Int) -> String? {
        switch cc {
        case 0: return "Bank"
        case 1: return "Mod Wheel"
        case 2: return "Breath"
        case 4: return "Foot"
        case 5: return "Porta Time"
        case 7: return "Volume"
        case 8: return "Balance"
        case 10: return "Pan"
        case 11: return "Expression"
        case 64: return "Sustain"
        case 65: return "Portamento"
        case 66: return "Sostenuto"
        case 67: return "Soft Pedal"
        case 71: return "Resonance"
        case 72: return "Release"
        case 73: return "Attack"
        case 74: return "Cutoff"
        case 84: return "Porta Ctl"
        case 91: return "Reverb"
        case 93: return "Chorus"
        case 120: return "All Sound Off"
        case 123: return "All Notes Off"
        default: return nil
        }
    }

    // MARK: Device panel

    @ViewBuilder
    private func devicePanel(_ device: MIDIInputService.DeviceActivity) -> some View {
        let isPlaceholder = device.id == "placeholder"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "pianokeys")
                    .font(.caption)
                    .foregroundStyle(.pink)
                Text(isPlaceholder
                     ? "No MIDI device connected - plug one in and this goes live"
                     : device.name)
                    .font(.caption.weight(isPlaceholder ? .regular : .semibold))
                    .foregroundStyle(isPlaceholder ? .secondary : .primary)
                Spacer()
                if let program = device.lastProgram {
                    Text("Program \(program)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.pink.opacity(0.14)))
                }
                if !device.notesDown.isEmpty {
                    Text(device.notesDown.sorted().map { MIDIService.noteName($0) }.joined(separator: " "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.pink)
                        .lineLimit(1)
                }
            }

            keyboardStrip(device)
            knobRow(device)

            HStack(alignment: .top, spacing: 14) {
                bendWidget(device)
                aftertouchWidget(device)
                channelStrip(device)
                Spacer(minLength: 0)
            }

            if !device.recent.isEmpty {
                eventLog(device)
            }
        }
    }

    // MARK: Keyboard strip

    private func boundNotes(deviceID: String) -> Set<Int> {
        var bound: Set<Int> = []
        for group in preset.joysticks {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == .note {
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                bound.insert(binding.input.index)
            }
        }
        return bound
    }

    private static func isBlackKey(_ note: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(note % 12)
    }

    @ViewBuilder
    private func keyboardStrip(_ device: MIDIInputService.DeviceActivity) -> some View {
        let bound = boundNotes(deviceID: device.id)
        let held = device.notesDown
        let velocities = device.velocities
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
                let whiteW = size.width / CGFloat(whites.count)
                for (i, note) in whites.enumerated() {
                    let rect = CGRect(x: CGFloat(i) * whiteW, y: 0,
                                      width: whiteW - 1, height: size.height)
                    let path = Path(roundedRect: rect, cornerRadius: 1.5)
                    if held.contains(note) {
                        // Velocity shading: soft touches glow lighter.
                        let vel = Double(velocities[note] ?? 100) / 127.0
                        context.fill(path, with: .color(.pink.opacity(0.45 + 0.55 * vel)))
                    } else {
                        context.fill(path, with: .color(.secondary.opacity(0.22)))
                    }
                    if bound.contains(note) {
                        let dot = CGRect(x: rect.midX - 1.5, y: size.height - 6,
                                         width: 3, height: 3)
                        context.fill(Path(ellipseIn: dot),
                                     with: .color(held.contains(note) ? .white : .pink))
                    }
                }
                var whiteIndex = 0
                for note in Self.lowNote...Self.highNote {
                    if Self.isBlackKey(note) {
                        let x = CGFloat(whiteIndex) * whiteW - whiteW * 0.3
                        let rect = CGRect(x: x, y: 0,
                                          width: whiteW * 0.6, height: size.height * 0.6)
                        let path = Path(roundedRect: rect, cornerRadius: 1.5)
                        if held.contains(note) {
                            let vel = Double(velocities[note] ?? 100) / 127.0
                            context.fill(path, with: .color(.pink.opacity(0.45 + 0.55 * vel)))
                        } else {
                            context.fill(path, with: .color(.primary.opacity(0.55)))
                        }
                        if bound.contains(note) {
                            let dot = CGRect(x: rect.midX - 1.5, y: rect.maxY - 5,
                                             width: 3, height: 3)
                            context.fill(Path(ellipseIn: dot),
                                         with: .color(held.contains(note) ? .white : .pink))
                        }
                    } else {
                        whiteIndex += 1
                    }
                }
            }
            .frame(height: 44)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { stripWidthEstimate = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in stripWidthEstimate = w }
            })
            .contentShape(Rectangle())
            .onTapGesture { location in
                openInspector = "keys-\(device.id)-\(noteAt(location: location))"
            }
            .popover(isPresented: inspectorPresented(prefix: "keys-\(device.id)-")) {
                if let key = openInspector,
                   let note = Int(key.split(separator: "-").last ?? "") {
                    midiInspector(title: "\(MIDIService.noteName(note)) (note \(note))",
                                  kind: .note, number: note, device: device)
                }
            }
            .help("Keys glow with press strength. A dot marks a bound note. Click a key to see its bindings.")

            // Octave labels under every C.
            HStack(spacing: 0) {
                let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
                ForEach(whites, id: \.self) { note in
                    Text(note % 12 == 0 ? "C\(note / 12 - 2)" : "")
                        .font(.system(size: 7, weight: .medium).monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func noteAt(location: CGPoint) -> Int {
        let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
        let fraction = max(0, min(0.999, location.x / max(1, stripWidthEstimate)))
        let index = Int(fraction * CGFloat(whites.count))
        return whites[min(index, whites.count - 1)]
    }

    // MARK: Knob row

    private func boundCCs(deviceID: String) -> [Int] {
        var found = Set<Int>()
        for group in preset.joysticks {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == .cc {
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                found.insert(binding.input.index)
            }
        }
        return found.sorted()
    }

    private func ccBadge(cc: Int, deviceID: String) -> (label: String, color: Color)? {
        for group in preset.joysticks {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == .cc
                && binding.input.index == cc {
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                if binding.outputs.contains(where: { $0.type == .absoluteVolume }) {
                    return ("Fader", .teal)
                }
                switch binding.input.midiCCMode {
                case .centered: return ("Dial", .orange)
                case .relative: return ("Turn", .indigo)
                default: return ("Switch", .secondary)
                }
            }
        }
        return nil
    }

    @ViewBuilder
    private func knobRow(_ device: MIDIInputService.DeviceActivity) -> some View {
        // Bound CCs always show, live or at rest, so the panel mirrors the
        // preset before anything is touched; CCs the hardware has sent but
        // the preset doesn't bind follow, most recently moved first.
        let bound = boundCCs(deviceID: device.id)
        let seenByCC = Dictionary(device.ccs.map { ($0.cc, $0) },
                                  uniquingKeysWith: { a, b in a.stamp > b.stamp ? a : b })
        let boundKnobs: [MIDIInputService.CCActivity] = bound.map { cc in
            seenByCC[cc] ?? MIDIInputService.CCActivity(
                deviceID: device.id, channel: 1, cc: cc, value: 0, stamp: 0)
        }
        let extras = device.ccs.filter { !bound.contains($0.cc) }
        let knobs = Array((boundKnobs + extras).prefix(Self.maxKnobs))
        if knobs.isEmpty {
            Text("Twist a knob or move a slider - every control appears here live.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            let newest = knobs.map(\.stamp).max() ?? 0
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(knobs) { knob in
                        knobWidget(knob,
                                   isNewest: newest > 0 && knob.stamp == newest,
                                   device: device)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func knobWidget(_ knob: MIDIInputService.CCActivity, isNewest: Bool,
                            device: MIDIInputService.DeviceActivity) -> some View {
        let badge = ccBadge(cc: knob.cc, deviceID: device.id)
        let fraction = Double(knob.value) / 127.0
        Button {
            openInspector = "cc-\(device.id)-\(knob.cc)"
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .trim(from: 0.125, to: 0.875)
                        .stroke(Color.secondary.opacity(0.25),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(90))
                    Circle()
                        .trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                        .stroke(isNewest ? Color.pink : Color.secondary.opacity(0.75),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(90))
                    Text(knob.stamp == 0 ? "-" : "\(knob.value)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isNewest ? .primary : .secondary)
                }
                .frame(width: 36, height: 36)
                Text("CC \(knob.cc)")
                    .font(.system(size: 8, weight: .medium).monospaced())
                    .foregroundStyle(.secondary)
                if let name = Self.ccName(knob.cc) {
                    Text(name)
                        .font(.system(size: 7.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let badge {
                    Text(badge.label)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(badge.color.opacity(0.14)))
                }
            }
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .popover(isPresented: inspectorPresented(exact: "cc-\(device.id)-\(knob.cc)")) {
            midiInspector(title: ccTitle(knob.cc), kind: .cc, number: knob.cc, device: device)
        }
        .help("Control Change \(knob.cc)\(Self.ccName(knob.cc).map { " (\($0))" } ?? ""), value \(knob.stamp == 0 ? "not seen yet" : String(knob.value)). Click to see its bindings.")
    }

    private func ccTitle(_ cc: Int) -> String {
        if let name = Self.ccName(cc) { return "CC \(cc) · \(name)" }
        return "CC \(cc)"
    }

    // MARK: Meters

    @ViewBuilder
    private func bendWidget(_ device: MIDIInputService.DeviceActivity) -> some View {
        let bend = device.pitchBend ?? 0
        Button {
            openInspector = "bend-\(device.id)"
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pitch Bend")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                        .frame(width: 90, height: 6)
                    Rectangle().fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 10)
                        .offset(x: 45)
                    Circle()
                        .fill(abs(bend) > 0.01 ? Color.pink : Color.secondary)
                        .frame(width: 10, height: 10)
                        .offset(x: 40 + CGFloat(bend) * 45)
                }
                .frame(height: 12)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: inspectorPresented(exact: "bend-\(device.id)")) {
            midiInspector(title: "Pitch Bend", kind: .pitchBend, number: nil, device: device)
        }
    }

    @ViewBuilder
    private func aftertouchWidget(_ device: MIDIInputService.DeviceActivity) -> some View {
        let touch = device.aftertouch ?? 0
        Button {
            openInspector = "touch-\(device.id)"
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aftertouch")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                        .frame(width: 60, height: 6)
                    Capsule()
                        .fill(touch > 0 ? Color.pink : Color.clear)
                        .frame(width: max(0, 60 * CGFloat(touch) / 127), height: 6)
                }
                .frame(height: 12)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: inspectorPresented(exact: "touch-\(device.id)")) {
            midiInspector(title: "Aftertouch", kind: .aftertouch, number: nil, device: device)
        }
    }

    /// Sixteen channel slots; ones this device has spoken on fill in, and
    /// the freshest is highlighted.
    @ViewBuilder
    private func channelStrip(_ device: MIDIInputService.DeviceActivity) -> some View {
        let freshest = device.channelStamps.max(by: { $0.value < $1.value })?.key
        VStack(alignment: .leading, spacing: 2) {
            Text("Channels")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(1...16, id: \.self) { channel in
                    let seen = device.channelStamps[channel] != nil
                    Circle()
                        .fill(channel == freshest ? Color.pink
                              : seen ? Color.secondary.opacity(0.6)
                              : Color.secondary.opacity(0.15))
                        .frame(width: 6, height: 6)
                        .help("Channel \(channel)\(seen ? "" : " - no messages yet")")
                }
            }
            .frame(height: 12)
        }
    }

    // MARK: Event log

    @ViewBuilder
    private func eventLog(_ device: MIDIInputService.DeviceActivity) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(device.recent.prefix(4).enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: 8.5).monospaced())
                        .foregroundStyle(index == 0 ? Color.secondary : Color.secondary.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if device.eventCount > 0 {
                Text("\(device.eventCount) events")
                    .font(.system(size: 8.5).monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Inspector

    private func inspectorPresented(exact: String) -> Binding<Bool> {
        Binding(get: { openInspector == exact },
                set: { if !$0 { openInspector = nil } })
    }

    private func inspectorPresented(prefix: String) -> Binding<Bool> {
        Binding(get: { openInspector?.hasPrefix(prefix) == true },
                set: { if !$0 { openInspector = nil } })
    }

    private struct MIDIBindingMatch: Identifiable {
        let id: UUID
        let joystickIndex: Int
        let binding: BindingModel
    }

    private func matches(kind: MIDIInputKind, number: Int?, deviceID: String) -> [MIDIBindingMatch] {
        var found: [MIDIBindingMatch] = []
        for (joystickIndex, group) in preset.joysticks.enumerated() {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == kind {
                if let number, binding.input.index != number { continue }
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                found.append(MIDIBindingMatch(id: binding.id,
                                              joystickIndex: joystickIndex,
                                              binding: binding))
            }
        }
        return found
    }

    @ViewBuilder
    private func midiInspector(title: String, kind: MIDIInputKind, number: Int?,
                               device: MIDIInputService.DeviceActivity) -> some View {
        let matchingBindings = matches(kind: kind, number: number, deviceID: device.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Spacer()
                if !matchingBindings.isEmpty {
                    Text("\(matchingBindings.count) bound")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if matchingBindings.isEmpty {
                Text("No bindings in this preset target this input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matchingBindings) { match in
                    Button {
                        openInspector = nil
                        onJump?(EditorJumpTarget(
                            joystickIndex: match.joystickIndex,
                            inputSerialized: match.binding.input.serialized
                        ))
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.binding.input.displayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(match.binding.outputs.map(\.displayName).joined(separator: " + "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.forward.circle")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 230, alignment: .leading)
    }
}
