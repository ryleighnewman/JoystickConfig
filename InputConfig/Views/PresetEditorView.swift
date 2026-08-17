import SwiftUI

/// Payload that asks the editor to scroll to and highlight a specific
/// binding row. Posted from the Live Visualizer popovers via the
/// `inputConfigJumpToBinding` notification and routed in by ContentView.
struct EditorJumpTarget: Equatable, Hashable {
    /// Joystick index the visualizer click came from. The editor uses this
    /// to disambiguate when multiple joystick groups all bind the same input
    /// (e.g. two controllers each mapping Button A).
    let joystickIndex: Int
    /// Serialized form of the InputEvent (e.g. "axi 0 +", "btn 5"). Matched
    /// against every binding's `input.serialized` to locate the right row.
    let inputSerialized: String
    /// Re-triggers the jump even when the user clicks the same widget twice
    /// in a row. Equatable comparison includes this token.
    var token: UUID = UUID()
}

/// Full-featured preset editor with joystick groups and bindings.
/// Shows live input highlighting via mappingEngine environment object.
struct PresetEditorView: View {
    @State var preset: Preset
    /// True when the mapping engine was active at the moment the editor
    /// opened. Drives the "Engine paused while editing" banner so the user
    /// sees why their preset stopped firing inputs.
    var enginePausedNotice: Bool = false
    /// Optional jump-to-row request set by ContentView when the user clicks
    /// an input on the Live Visualizer. nil for a normal open.
    var pendingJump: EditorJumpTarget? = nil
    let onSave: (Preset) -> Void

    @EnvironmentObject var controllerService: GameControllerService
    // PresetEditorView itself never reads the mapping engine; only the child
    // JoystickGroupView rows do, and they inherit it from the sheet-level
    // injection in ContentView. Subscribing here rebuilt the ENTIRE editor body
    // on every 10-30 Hz engine publish while a preset was active.
    @EnvironmentObject var presetStore: PresetStore
    @Environment(\.dismiss) private var dismiss

    @State private var scanningBinding: (joystickIndex: Int, bindingIndex: Int)?
    @State private var showingScanOverlay = false

    /// Identifies which header text field (if any) currently owns the
    /// keyboard focus. Used to:
    /// 1. Let the user click anywhere outside the field to deselect it.
    /// 2. Force focus off when a scan starts, so keypresses don't type
    ///    into the name/tag field while the user is trying to scan
    ///    a controller input.
    @FocusState private var focusedHeaderField: HeaderField?
    private enum HeaderField: Hashable { case name, tag }
    @State private var preSortSnapshot: [JoystickMapping]?
    /// UUID of the binding row currently pulsing yellow because we just
    /// jumped to it. nil when no pulse is active.
    @State private var pulsingBindingID: UUID?
    /// After a directional scan we pop a confirmation dialog asking whether
    /// to wire the input directly to mouse motion or just record it raw and
    /// let the user assign an output manually.
    @State private var pendingScanMapping: PendingScanMapping?

    /// Carries the scan result + the binding location through the
    /// confirmation dialog. We have to keep these together because
    /// confirmationDialog's button closures need the data captured at the
    /// time of presentation.
    private struct PendingScanMapping: Identifiable {
        let id = UUID()
        let event: InputEvent
        let joystickIndex: Int
        let bindingIndex: Int
        /// True for axis + touchpad. We don't prompt on plain button taps.
        let isDirectional: Bool
        /// True only for touchpad inputs - drives the "Calibrate touchpad
        /// first" hint and the optional Region path.
        let isTouchpad: Bool
    }

    // Unlimited undo/redo: every time the preset changes we push the
    // previous state onto undoStack. Redo is populated when the user
    // undoes - undoing pushes the current state onto redoStack so they
    // can redo back up the chain. A small flag `isApplyingHistory`
    // prevents the change observer from re-recording history during
    // undo/redo itself.
    @State private var undoStack: [Preset] = []
    @State private var redoStack: [Preset] = []
    @State private var isApplyingHistory: Bool = false
    @State private var lastSnapshot: Preset? = nil

    /// Drives the Calibrate Touchpad sheet. Only shown when at least one
    /// connected controller reports a touchpad (DualSense, DualSense Edge,
    /// DualShock 4, etc.).
    @State private var showingTouchpadCalibration: Bool = false
    /// Drives the Calibrate Motion sheet from the toolbar button.
    @State private var showingMotionCalibration: Bool = false
    /// True when a motion input was scanned but no controller is yet
    /// calibrated. Drives an alert that offers to jump into calibration.
    @State private var pendingMotionCalibrationOffer: Bool = false

    /// Brief toast shown after the Quick Zero toolbar button fires so
    /// users get visible confirmation that the snapshot calibration
    /// landed (the actual save is silent on disk).
    @State private var showQuickZeroToast: Bool = false
    @State private var quickZeroToastMessage: String = ""

    /// True when any connected controller has a touchpad surface. The
    /// Calibrate Touchpad toolbar button is hidden otherwise.
    private var hasTouchpadCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.hasTouchpad }
    }

    /// True when any connected controller exposes motion sensors. Drives
    /// the Calibrate Motion toolbar button's visibility.
    private var hasMotionCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.supportsMotion }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack, deliberately NOT lazy. The editor has only a
                // handful of top-level sections, but one of them (a joystick
                // group) can be thousands of points tall. LazyVStack's item
                // phase tracking oscillates on huge children during fast
                // scrolling (LazyLayoutViewCache.updateItemPhase kept
                // re-dirtying the graph mid-layout), hanging the app. Eager
                // layout is deterministic and converges in one pass.
                VStack(alignment: .leading, spacing: 16) {
                    if enginePausedNotice {
                        enginePausedBanner
                    }

                    headerSection

                    Divider()

                    ForEach(preset.joysticks.indices, id: \.self) { index in
                        // Guard the subscript: while a group is being removed, a
                        // retained JoystickGroupView can re-render (on a live
                        // controller publish) with a now-out-of-range index.
                        if preset.joysticks.indices.contains(index) {
                            let joystick = preset.joysticks[index]
                            JoystickGroupView(
                                joystick: binding(for: index),
                                joystickIndex: index,
                                controllerName: controllerService.controllerName(at: index),
                                onAddBinding: { addBinding(to: index) },
                                onRemoveBinding: { bindIdx in removeBinding(at: bindIdx, from: index) },
                                onDuplicateBinding: { bindIdx in duplicateBinding(at: bindIdx, in: index) },
                                onScanInput: { bindIdx in startScan(joystickIndex: index, bindingIndex: bindIdx) },
                                onSortBindings: { sortBindings(in: index) },
                                onDuplicate: { duplicateJoystick(at: index) },
                                onRemoveJoystick: { removeJoystick(at: index) },
                                pulsingBindingID: pulsingBindingID,
                                // Plain values so the row views stay free of
                                // store subscriptions; used by the App Action
                                // output's target-preset picker.
                                availablePresets: presetStore.presets.map { (id: $0.id, name: $0.name) }
                            )
                            .id(joystick.id)
                        }
                    }
                    // Suppress the implicit remove transition so a deleted group
                    // is not retained (and re-rendered against a stale index)
                    // during a fade, mirroring the bindings list.
                    .animation(nil, value: preset.joysticks.count)

                    Button {
                        withAnimation {
                            preset.joysticks.append(JoystickMapping(tag: "<write comments here>"))
                        }
                    } label: {
                        Label("Add a new Joystick", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                                    .foregroundStyle(.green.opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.vertical, 8)

                    // Per-preset Automation: cursor / gaming utilities + auto-
                    // launch an app on activation. The collapsed state
                    // is a single-line summary; expanding reveals the
                    // toggles + path picker.
                    PresetAutomationSection(automation: $preset.automation)
                        .id("editor-automation")

                    // MARK: Accessibility Tools Suite
                    // Alternative-input schemes built for accessibility, with
                    // One-Stick Driving as the first tool. Anchored at the
                    // bottom as its own named category so it reads as a suite
                    // that will grow, not a stray extra.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "figure.roll")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Accessibility Tools Suite")
                                    .font(.headline)
                                Text("Alternative input schemes built for accessibility.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)

                        DriveModeSection(driveConfig: $preset.driveConfig)
                            .id("editor-drive")
                    }
                    .padding(.top, 6)
                }
                .padding(20)
                // Transparent tap-anywhere layer that releases keyboard
                // focus from the Name / Tag fields. Child controls
                // (TextFields, Buttons, Pickers) hit-test first and keep
                // their normal click behaviour; only a click on empty
                // editor whitespace falls through here.
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { focusedHeaderField = nil }
                )
            }
            // Content dissolves under the (now background-free) toolbar so the
            // top of the box reads like the glass body, matching the main
            // window instead of a distinct toolbar band.
            .headerFade()
            .navigationTitle("Edit Bindings & Mappings")
            .overlay(alignment: .top) {
                // Brief confirmation toast for the Quick Zero toolbar
                // button. Calibration save is silent on disk; the toast
                // gives the user visible confirmation the click took
                // effect. Auto-dismisses ~2 s after quickZeroGyro fires.
                if showQuickZeroToast {
                    Text(quickZeroToastMessage)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .liquidGlass(in: Capsule())
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityLabel(quickZeroToastMessage)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.easeOut(duration: 0.2), value: showQuickZeroToast)
            .onAppear {
                if lastSnapshot == nil { lastSnapshot = preset }
            }
            .onChange(of: preset) { _, _ in recordHistory() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.solidSecondary)
                        .spotlightAnchor(SpotlightID.editorCancel)
                        .accessibilityLabel("Cancel editing")
                        .accessibilityHint("Discards unsaved changes and closes the editor")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(preset)
                        dismiss()
                    }
                    .buttonStyle(.solid)
                    .spotlightAnchor(SpotlightID.editorSave)
                    .accessibilityLabel("Save preset")
                    .accessibilityHint("Saves the current bindings and closes the editor")
                }
                // Undo / Redo. Available everywhere in the editor and bound
                // to the standard Cmd+Z / Cmd+Shift+Z shortcuts.
                ToolbarItem(placement: .automatic) {
                    Button {
                        performUndo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(undoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo")
                    .accessibilityLabel("Undo")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        performRedo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(redoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo")
                    .accessibilityLabel("Redo")
                }
                // Touchpad calibration button - only visible when a
                // touchpad-capable controller (DualSense / DS4) is connected.
                if hasTouchpadCapableController {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showingTouchpadCalibration = true
                        } label: {
                            Label("Calibrate Touchpad", systemImage: "rectangle.and.hand.point.up.left.fill")
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        .help("Calibrate the touchpad surface so swipes feel uniform")
                    }
                }
                // Motion calibration button - visible when at least one
                // motion-capable controller is connected. Mirrors the
                // touchpad calibration button so editing a motion preset
                // can reach calibration in one click.
                if hasMotionCapableController {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showingMotionCalibration = true
                        } label: {
                            Label("Calibrate Motion", systemImage: "gyroscope")
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        .help("Set the resting zero for the controller's gyro and accelerometer")
                    }
                    // Quick zero gyro: lives right next to the Motion
                    // calibration button so users see the relationship
                    // (one is a multi-second still-hold capture; this
                    // one is a one-frame snapshot for fast re-zeroing
                    // when the controller is already at rest).
                    ToolbarItem(placement: .automatic) {
                        Button {
                            quickZeroGyro()
                        } label: {
                            Label("Quick Zero", systemImage: "scope")
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        .help("Snapshot current gyro reading as the new zero (place controller flat first)")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Sort All Bindings") {
                            preSortSnapshot = preset.joysticks
                            withAnimation { preset.sortBindings() }
                        }

                        if preSortSnapshot != nil {
                            Button("Undo Sort") {
                                if let snapshot = preSortSnapshot {
                                    withAnimation { preset.joysticks = snapshot }
                                    preSortSnapshot = nil
                                }
                            }
                        }

                        Divider()
                        Menu("Convert Controller Type...") {
                            ForEach(ControllerType.allCases) { source in
                                Menu("From \(source.rawValue)") {
                                    ForEach(ControllerType.allCases.filter { $0 != source }) { dest in
                                        Button("To \(dest.rawValue)") {
                                            preset = ControllerType.convert(preset: preset, from: source, to: dest)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.16), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More: sort, undo sort, convert controller type")
                    .accessibilityLabel("More actions")
                    .accessibilityHint("Sort all bindings, undo sort, or convert controller type")
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .sheet(isPresented: $showingTouchpadCalibration) {
                TouchpadCalibrationView()
                    .environmentObject(presetStore)
                    .glassBackground()
            }
            .sheet(isPresented: $showingMotionCalibration) {
                MotionCalibrationView()
                    .environmentObject(controllerService)
                    .glassBackground()
            }
            .alert("Calibrate motion first?",
                   isPresented: $pendingMotionCalibrationOffer) {
                Button("Calibrate now") {
                    showingMotionCalibration = true
                }
                Button("Skip", role: .cancel) { }
            } message: {
                Text("You just scanned a gyroscope input. Without calibration, a still controller will still slowly drift the cursor. Run a 2-second calibration to set the resting zero.")
            }
            // Post-scan prompt for axis + touchpad inputs: offer to auto-wire
            // the matching mouse motion, or keep the input raw so the user
            // can choose an output manually. For touchpad inputs we also
            // surface a one-tap "Calibrate first" shortcut so the resulting
            // mouse motion uses the user's actual touchpad bounds.
            .confirmationDialog(
                pendingScanMapping?.event.displayName ?? "Scanned input",
                isPresented: Binding(
                    get: { pendingScanMapping != nil },
                    set: { newValue in
                        if newValue == false { pendingScanMapping = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let pending = pendingScanMapping {
                    Button("Auto-map to mouse motion") {
                        applyScanMapping(pending, kind: .mouse)
                        pendingScanMapping = nil
                    }
                    if pending.isTouchpad {
                        Button("Calibrate touchpad first…") {
                            // Leave the raw input on the binding; user can
                            // come back and auto-map after calibrating.
                            applyScanMapping(pending, kind: .raw)
                            pendingScanMapping = nil
                            showingTouchpadCalibration = true
                        }
                    }
                    Button("Keep raw, I'll pick the output", role: .cancel) {
                        applyScanMapping(pending, kind: .raw)
                        pendingScanMapping = nil
                    }
                }
            } message: {
                if let pending = pendingScanMapping {
                    if pending.isTouchpad {
                        Text("This is a touchpad input. Auto-map sends mouse motion in the matching direction. If your touchpad hasn't been calibrated yet, calibrating first will make the cursor speed feel right.")
                    } else {
                        Text("Auto-map sends mouse motion in the matching direction. Keep raw to wire your own output (key, MIDI, macro, etc.).")
                    }
                }
            }
            .overlay {
                if showingScanOverlay {
                    ScanOverlayView(
                        controllerService: controllerService,
                        onInputDetected: { event in
                            handleScannedInput(event)
                        },
                        onCancel: {
                            showingScanOverlay = false
                            controllerService.stopScanning()
                        }
                    )
                }
            }
            // Honor a pending jump-to-binding when the editor first appears,
            // and also any time ContentView updates the target (e.g. the user
            // clicks another input on the Live Visualizer while the editor is
            // already open).
            .onAppear {
                if let target = pendingJump {
                    performJump(to: target, using: proxy)
                }
            }
            .onChange(of: pendingJump) { _, newValue in
                if let target = newValue {
                    performJump(to: target, using: proxy)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToAutomation)) { _ in
                withAnimation(.easeInOut(duration: 0.6)) {
                    proxy.scrollTo("editor-automation", anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToFirstBinding)) { _ in
                // Scroll to the first binding's ID so the Options
                // disclosure is in view. preset.joysticks.first?.bindings.first
                // gives the row's id; ForEach in JoystickGroupView
                // applies .id(binding.id) so this resolves.
                if let firstID = preset.joysticks.first?.bindings.first?.id {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        proxy.scrollTo(firstID, anchor: .center)
                    }
                }
            }
            }  // ScrollViewReader
        }
    }

    // MARK: - Jump-to-binding

    /// Locate the binding row matching the jump target's joystick + input
    /// and scroll/pulse it. Walks the joystick group first to honor the
    /// click's controller-of-origin, then falls back to *any* joystick
    /// group that binds the same input.
    /// Snapshot every motion-capable connected controller's current
    /// gyro+accel reading and save it as their new resting baseline.
    /// One-frame variant of the multi-second still-hold capture in
    /// MotionCalibrationView; intended for quick re-zero when the
    /// controller is already at rest.
    private func quickZeroGyro() {
        var count = 0
        for controller in controllerService.connectedControllers {
            // Only zero controllers that actually report rotation; a controller
            // that exposes a motion object but no live gyro would otherwise
            // persist a baseline from undefined values. Gate accel separately.
            guard let motion = controller.motion, motion.hasRotationRate else { continue }
            let key = MotionCalibrationService.identityKey(for: controller)
            let hasAccel = motion.hasGravityAndUserAcceleration
            MotionCalibrationService.shared.quickZero(
                forKey: key,
                gyroX: Float(motion.rotationRate.x),
                gyroY: Float(motion.rotationRate.y),
                gyroZ: Float(motion.rotationRate.z),
                accelX: hasAccel ? Float(motion.userAcceleration.x) : 0,
                accelY: hasAccel ? Float(motion.userAcceleration.y) : 0,
                accelZ: hasAccel ? Float(motion.userAcceleration.z) : 0
            )
            count += 1
        }
        quickZeroToastMessage = count == 0
            ? "No motion-capable controller connected"
            : "Gyro zeroed on \(count) controller\(count == 1 ? "" : "s")"
        showQuickZeroToast = true
        // The toast is a transient overlay VoiceOver would otherwise miss.
        // Announce the same message so the outcome reaches VoiceOver users.
        AccessibilityNotification.Announcement(quickZeroToastMessage).post()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showQuickZeroToast = false
        }
    }

    private func performJump(to target: EditorJumpTarget, using proxy: ScrollViewProxy) {
        guard let bindingID = locateBindingID(for: target) else { return }
        // Slight delay so the editor has time to lay out before we scroll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.4)) {
                proxy.scrollTo(bindingID, anchor: .center)
            }
            pulsingBindingID = bindingID
        }
        // Clear the pulse after the ring fades out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if pulsingBindingID == bindingID {
                pulsingBindingID = nil
            }
        }
    }

    private func locateBindingID(for target: EditorJumpTarget) -> UUID? {
        // 1) Prefer a binding in the joystick group that matches the
        // visualizer's controller slot.
        if target.joystickIndex < preset.joysticks.count {
            let group = preset.joysticks[target.joystickIndex]
            if let hit = group.bindings.first(where: { $0.input.serialized == target.inputSerialized }) {
                return hit.id
            }
        }
        // 2) Fall back: search every joystick for any binding that matches.
        for group in preset.joysticks {
            if let hit = group.bindings.first(where: { $0.input.serialized == target.inputSerialized }) {
                return hit.id
            }
        }
        return nil
    }

    // MARK: - Engine Paused Banner

    /// Yellow banner at the top of the editor while a preset is being edited
    /// over a running engine. Outputs are paused (no cursor motion, no
    /// keystrokes, no MIDI) but the engine keeps polling inputs so the green
    /// row highlight still fires when you press a button on the controller.
    /// Outputs resume automatically when the editor closes.
    private var enginePausedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.title3)
                .iconTint(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Outputs paused while editing")
                    .font(.subheadline.weight(.semibold))
                Text("Your active preset is still detecting inputs so binding rows highlight as you press buttons, but the cursor, keystrokes, and MIDI are paused. Outputs resume when you close the editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.55), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Name:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                TextField("Preset Name", text: $preset.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedHeaderField, equals: .name)
            }
            HStack {
                Text("Tag:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                TextField("Tag / Description", text: $preset.tag)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedHeaderField, equals: .tag)
            }
        }
    }

    // MARK: - Undo / Redo

    /// Record the previous preset value before a change. Called from the
    /// editor's `.onChange(of: preset)` observer. Skips recording when
    /// `isApplyingHistory` is true so undo/redo themselves don't pollute
    /// the history. Redo is cleared on any fresh edit, like every other
    /// editor on the planet.
    private func recordHistory() {
        guard !isApplyingHistory else { return }
        if let previous = lastSnapshot, previous != preset {
            undoStack.append(previous)
            // Bound the history so a long editing session can't grow an
            // unbounded stack of whole-preset deep copies.
            if undoStack.count > 100 {
                undoStack.removeFirst(undoStack.count - 100)
            }
            redoStack.removeAll()
        }
        lastSnapshot = preset
    }

    private func performUndo() {
        guard let previous = undoStack.popLast() else { return }
        isApplyingHistory = true
        redoStack.append(preset)
        preset = previous
        lastSnapshot = previous
        DispatchQueue.main.async { isApplyingHistory = false }
    }

    private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        isApplyingHistory = true
        undoStack.append(preset)
        preset = next
        lastSnapshot = next
        DispatchQueue.main.async { isApplyingHistory = false }
    }

    // MARK: - Binding Helpers

    private func binding(for joystickIndex: Int) -> SwiftUI.Binding<JoystickMapping> {
        // Bounds-safe: a binding captured by a group that is mid-removal must
        // never trap if it is read once more before SwiftUI tears the row down.
        SwiftUI.Binding(
            get: { preset.joysticks.indices.contains(joystickIndex)
                   ? preset.joysticks[joystickIndex] : JoystickMapping() },
            set: { if preset.joysticks.indices.contains(joystickIndex) {
                       preset.joysticks[joystickIndex] = $0 } }
        )
    }

    private func addBinding(to joystickIndex: Int) {
        withAnimation {
            let newBinding = BindingModel(
                input: InputEvent.button(0),
                outputs: [OutputAction(type: .key, keyCode: 4)]
            )
            preset.joysticks[joystickIndex].bindings.append(newBinding)
        }
    }

    private func removeBinding(at bindingIndex: Int, from joystickIndex: Int) {
        withAnimation {
            preset.joysticks[joystickIndex].bindings.remove(at: bindingIndex)
        }
    }

    private func duplicateBinding(at bindingIndex: Int, in joystickIndex: Int) {
        withAnimation {
            let original = preset.joysticks[joystickIndex].bindings[bindingIndex]
            // duplicated() carries every advanced field; the bare
            // initializer silently dropped turbo, macros, deadzone, etc.
            let clone = original.duplicated()
            preset.joysticks[joystickIndex].bindings.insert(clone, at: bindingIndex + 1)
        }
    }

    private func sortBindings(in joystickIndex: Int) {
        // Delegate to the model's authoritative sort which covers every
        // InputType case. Earlier this view had its own truncated
        // table (button/axis/hat only) that silently collapsed every
        // other input type to slot 0 in the editor list.
        withAnimation {
            preset.joysticks[joystickIndex].bindings.sort { a, b in
                let aOrder = Self.bindingSortOrder(for: a.input.type)
                let bOrder = Self.bindingSortOrder(for: b.input.type)
                if aOrder != bOrder { return aOrder < bOrder }
                return a.input.index < b.input.index
            }
        }
    }

    private static func bindingSortOrder(for type: InputType) -> Int {
        switch type {
        case .button:          return 0
        case .axis:            return 1
        case .hat:             return 2
        case .touchpad:        return 3
        case .touchpadRegion:  return 4
        case .touchpadGesture: return 5
        case .motion:          return 6
        case .extKey:          return 7
        case .extMouse:        return 8
        case .cursorRegion:    return 9
        case .stickRegion:     return 10
        case .midi:            return 11
        }
    }

    private func duplicateJoystick(at index: Int) {
        withAnimation {
            var clone = preset.joysticks[index]
            clone = JoystickMapping(
                tag: clone.tag,
                bindings: clone.bindings.map { $0.duplicated() }
            )
            preset.joysticks.insert(clone, after: index)
        }
    }

    private func removeJoystick(at index: Int) {
        withAnimation {
            preset.joysticks.remove(at: index)
        }
    }

    // MARK: - Scanning

    private func startScan(joystickIndex: Int, bindingIndex: Int) {
        // Release any keyboard focus from the Name / Tag fields so that
        // pressing keys during scan doesn't accidentally type into them.
        // (The user's intent during a scan is to identify a controller
        // input, not to edit the preset name.)
        focusedHeaderField = nil
        scanningBinding = (joystickIndex, bindingIndex)
        showingScanOverlay = true
        controllerService.startScanning { event in
            // Input received - handled in handleScannedInput
        }
    }

    private func handleScannedInput(_ event: InputEvent) {
        guard let scanning = scanningBinding else { return }
        // Always record the input on the binding so the row reflects what
        // the user just scanned.
        preset.joysticks[scanning.joystickIndex].bindings[scanning.bindingIndex].input = event
        showingScanOverlay = false
        controllerService.stopScanning()

        // Motion-scanned input: gate on calibration. If no motion-capable
        // controller has been calibrated, prompt the user to run calibration
        // first - tilt-to-aim feels wrong otherwise.
        if event.type == .motion {
            let anyCalibrated = controllerService.connectedControllers.contains { ctrl in
                let key = MotionCalibrationService.identityKey(for: ctrl)
                return MotionCalibrationService.shared.isCalibrated(forKey: key)
            }
            if !anyCalibrated {
                // Show ONLY the calibration offer, not the auto-map dialog on
                // top of it. The motion input is already recorded on the
                // binding; the user calibrates first, then wires the output.
                pendingMotionCalibrationOffer = true
                scanningBinding = nil
                return
            }
        }

        // For axis + touchpad + motion inputs, offer to auto-wire the
        // output. Plain button presses don't get this dialog - the user
        // already knows it's a button-style binding.
        let isAxis = event.type == .axis
        let isTouchpad = event.type == .touchpad
        let isMotion = event.type == .motion
        if isAxis || isTouchpad || isMotion {
            pendingScanMapping = PendingScanMapping(
                event: event,
                joystickIndex: scanning.joystickIndex,
                bindingIndex: scanning.bindingIndex,
                isDirectional: true,
                isTouchpad: isTouchpad
            )
        }

        scanningBinding = nil
    }

    /// Apply the user's choice from the post-scan confirmation dialog.
    /// `.mouse` auto-wires a mouse-motion output in the matching direction;
    /// `.raw` keeps just the recorded input and lets the user pick an output
    /// manually. Used by both the axis-scan and touchpad-scan flows.
    private enum ScanAutoMapping { case mouse, raw }

    private func applyScanMapping(_ pending: PendingScanMapping, kind: ScanAutoMapping) {
        switch kind {
        case .raw:
            // Nothing to do - the input is already recorded.
            return
        case .mouse:
            // Translate the input direction into a sensible mouseMotion
            // output. Standard convention: axis 0/touchpad-X → horizontal,
            // axis 1/touchpad-Y → vertical. Direction flows straight from
            // the scanned event's axisDirection.
            let mouseAxis: MouseAxis
            let mouseDirection: MouseDirection
            switch pending.event.type {
            case .axis:
                // Even axes (0, 2, 4) are X-style, odd (1, 3) Y-style in MFi.
                mouseAxis = (pending.event.index % 2 == 0) ? .horizontal : .vertical
                mouseDirection = (pending.event.axisDirection == .negative) ? .negative : .positive
            case .touchpad:
                mouseAxis = (pending.event.touchpadAxis == .y) ? .vertical : .horizontal
                mouseDirection = (pending.event.axisDirection == .negative) ? .negative : .positive
            case .motion:
                // Gyro Y (yaw rate) -> horizontal mouse, Gyro X (pitch)
                // -> vertical mouse. Z (roll) is unusual to bind so we
                // default to horizontal too. Matches the Showcase: Gyro
                // Aim preset's defaults.
                switch pending.event.motionChannel {
                case .gyroY, .yawAngle:
                    mouseAxis = .horizontal
                case .gyroX, .pitchAngle:
                    mouseAxis = .vertical
                default:
                    mouseAxis = .horizontal
                }
                mouseDirection = (pending.event.axisDirection == .negative) ? .negative : .positive
            default:
                return
            }
            let speed: Int
            switch pending.event.type {
            case .touchpad: speed = 12
            case .motion:   speed = 14  // Gyro is sensitive; lower-than-stick speed feels right.
            default:        speed = 18
            }
            let output = OutputAction(type: .mouseMotion,
                                      mouseAxis: mouseAxis,
                                      mouseDirection: mouseDirection,
                                      speed: speed)
            preset.joysticks[pending.joystickIndex].bindings[pending.bindingIndex].outputs = [output]
            // Sensible defaults to make this feel like the showcase preset.
            var binding = preset.joysticks[pending.joystickIndex].bindings[pending.bindingIndex]
            binding.variableSensitivity = true
            if pending.event.type == .axis {
                // Mild smooth curve + moderate deadzone for joysticks.
                binding.deadzone = 0.10
                binding.sensitivityCurve = .exponential
            }
            preset.joysticks[pending.joystickIndex].bindings[pending.bindingIndex] = binding
        }
    }
}

// Helper extension for inserting after an index
private extension Array {
    mutating func insert(_ element: Element, after index: Int) {
        let insertIndex = Swift.min(index + 1, count)
        insert(element, at: insertIndex)
    }
}
