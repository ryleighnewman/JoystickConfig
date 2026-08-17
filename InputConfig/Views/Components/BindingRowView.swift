import SwiftUI
import Combine

/// A single binding row with fixed-width columns for consistent alignment.
struct BindingRowView: View {
    @SwiftUI.Binding var binding: BindingModel
    let onScan: () -> Void
    let onRemove: () -> Void
    var onDuplicate: (() -> Void)?
    var isHighlighted: Bool = false
    /// 1-based position of this binding within its joystick group. Drives the
    /// "#N" chip at the start of every row so the Live Visualizer can refer
    /// to a specific row by number.
    var displayNumber: Int = 0
    /// True while this row is the target of a jump-to-binding pulse triggered
    /// by clicking on the Live Visualizer. Shows a yellow ring for ~1.2 s.
    var isPulsing: Bool = false

    /// Named extra buttons exposed by the controller for this slot.
    /// Passed in as a plain value type by the parent so we don't have
    /// to inject `GameControllerService` as an `@EnvironmentObject` -
    /// avoids a strict-concurrency boundary and keeps this view
    /// trivially previewable. Empty when no controller is connected or
    /// the slot has no extras.
    var extraButtons: [GameControllerService.ExtraButton] = []

    /// Preset list for the App Action output's target picker, passed as
    /// plain values for the same previewability reason as extraButtons.
    var availablePresets: [(id: UUID, name: String)] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @State private var showAdvanced = false
    @State private var showMacroEditor = false
    @State private var showDeadzoneCalibration = false
    /// Region editors opened straight from the input pickers, so defining a
    /// missing cursor/stick region doesn't require a detour through Settings.
    @State private var showCursorRegionsEditor = false
    @State private var showStickRegionsEditor = false
    /// Drives the firing arrow's left-to-right sweep while highlighted.
    @State private var arrowShoot = false

    /// Live mirrors of slider values, updated every drag tick so the value
    /// shown next to each slider follows the thumb in real time. The
    /// underlying BindingModel still only commits on slider release to keep
    /// the editor's re-render chain off the per-frame hot path.
    @State private var liveSpeed: [Int: Double] = [:]
    @State private var liveHaptic: Double?
    @State private var liveDeadzone: Double?

    // Fixed column widths for perfect alignment
    private let dragWidth: CGFloat = 16
    private let scanColWidth: CGFloat = 54
    /// Wider than before (was 78) so the full input-type names like
    /// "Keyboard Key", "Cursor Region", "Stick Region" actually show
    /// in the picker label instead of getting truncated to "Keyboa..."
    /// which made the picker look locked.
    private let typeColWidth: CGFloat = 116
    private let indexColWidth: CGFloat = 124
    /// Wider than before (was 58) because for extKey / extMouse this
    /// column hosts the device picker, and device names like
    /// "Built-in Keyboard" overflowed and visually collided with the
    /// next column's keyboard icon.
    private let dirColWidth: CGFloat = 130
    private let arrowWidth: CGFloat = 24
    private let outTypeColWidth: CGFloat = 130
    private let actionsWidth: CGFloat = 48
    private let colGap: CGFloat = 8

    /// Total width of input columns (for sub-row indentation)
    private var inputColumnsWidth: CGFloat {
        dragWidth + scanColWidth + typeColWidth + indexColWidth + dirColWidth + arrowWidth + colGap * 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Primary row
            HStack(spacing: colGap) {
                // Row number chip - matches the number shown in the Live
                // Visualizer popover so users can find the right row when
                // they click an input on the visualizer.
                if displayNumber > 0 {
                    Text("#\(displayNumber)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .frame(width: 32, alignment: .leading)
                }

                // Non-color firing cue: the green highlight alone isn't
                // distinguishable with Differentiate Without Color on, so add
                // a bolt while the row is firing. VoiceOver already announces
                // the highlight state, hence the hidden marker.
                if isHighlighted && differentiateWithoutColor {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .iconTint(.green)
                        .accessibilityHidden(true)
                }

                // Drag handle
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: dragWidth)

                // INPUT column: scan + type + index + direction, leading
                // aligned inside a flexible half so the arrow sits centered
                // between the input and output sides instead of leaving a
                // dead gap after the fixed-width input controls.
                HStack(spacing: 6) {
                // COL 1: Scan
                Button("Scan", action: onScan)
                    .buttonStyle(.solidSecondaryMini)
                    .frame(width: scanColWidth, alignment: .center)
                    .accessibilityLabel("Scan binding \(displayNumber)")
                    .accessibilityHint("Press a button, key, or axis on your controller to record this binding")

                // COL 2: Input Type. A lazy Menu (matching KeyCodePicker and
                // the index picker) instead of Picker: NSPopUpButton-backed
                // Pickers pre-build every item on row creation, which made
                // scrolling the binding list hitch as rows materialized.
                // Grouped so the first decision on every row is no longer an
                // undifferentiated 11-item list.
                Menu {
                    Section("Controller") {
                        inputTypeChoice(.button)
                        inputTypeChoice(.axis)
                        inputTypeChoice(.hat)
                    }
                    Section("Touchpad") {
                        inputTypeChoice(.touchpad)
                        inputTypeChoice(.touchpadRegion)
                        inputTypeChoice(.touchpadGesture)
                    }
                    Section("Motion") {
                        inputTypeChoice(.motion)
                    }
                    Section("Keyboard & Mouse") {
                        inputTypeChoice(.extKey)
                        inputTypeChoice(.extMouse)
                    }
                    Section("Zones") {
                        inputTypeChoice(.cursorRegion)
                        inputTypeChoice(.stickRegion)
                    }
                } label: {
                    menuChevronLabel(binding.input.type.displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(width: typeColWidth, alignment: .leading)
                .accessibilityLabel("Input type")
                .accessibilityValue(binding.input.type.displayName)

                // COL 3: Index
                indexPicker
                    .frame(width: indexColWidth, alignment: .leading)
                    .accessibilityLabel(indexPickerAccessibilityLabel)
                    .accessibilityValue(indexPickerAccessibilityValue)

                // COL 4: Direction (or empty spacer for Button type)
                directionPicker
                    .frame(width: dirColWidth, alignment: .leading)
                    .accessibilityLabel(directionPickerAccessibilityLabel)
                    .accessibilityValue(directionPickerAccessibilityValue)

                }

                // Fixed-position arrow right after the input columns. The two
                // flexible `maxWidth: .infinity` halves that used to center it
                // forced SwiftUI to renegotiate each row's width with repeated
                // sizeThatFits probes; on a large preset that pegged the main
                // thread solid. Only the output side stays flexible now, so the
                // row lays out in a single pass.
                firingArrow

                // OUTPUT column: icon + type + value, with the row actions
                // pinned at the trailing edge.
                HStack(spacing: 6) {
                if !binding.outputs.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: outputIcon(for: binding.outputs[0]))
                            .font(.caption)
                            .foregroundStyle(outputColor(for: binding.outputs[0]))
                            .frame(width: 14)

                        Menu {
                            outputTypeMenuItems { firstOutputTypeBinding.wrappedValue = $0 }
                        } label: {
                            menuChevronLabel(binding.outputs[0].type.displayName)
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .accessibilityLabel("Output type")
                        .accessibilityValue(binding.outputs[0].type.displayName)
                    }
                    .frame(width: outTypeColWidth, alignment: .leading)

                    // Output value (flexible)
                    outputValueControls(at: 0)

                    if binding.outputs.count > 1 {
                        Button {
                            removeOutput(at: 0)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove this output")
                    }
                }

                Spacer(minLength: 4)

                // Actions
                HStack(spacing: 3) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            binding.outputs.append(OutputAction(type: .key, keyCode: 4))
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Add output")
                    .accessibilityLabel("Add output")

                    if let onDuplicate {
                        CopyIconButton(action: onDuplicate,
                                       helpText: "Duplicate this binding")
                            .accessibilityLabel("Duplicate this binding")
                    }

                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.7))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove binding")
                }
                .frame(width: actionsWidth + 18, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)
            }

            // Secondary output sub-rows
            secondaryOutputRows

            // Per-binding note: a short line describing what this control does.
            // Smart presets auto-fill it; users can edit or add their own.
            // Symmetric breathing room so it sits centered between the
            // mapping row above and the Options disclosure below.
            noteRow
                .padding(.vertical, 3)

            // Advanced options
            advancedSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.green.opacity(0.18) : Color.secondary.opacity(0.05))
                // Instant fade-in (so quick taps feel snappy), longer fade-out (so the
// green dwell tracks the latched visibility period from
// GameControllerService.rawActiveExpiry).
.animation(isHighlighted ? .linear(duration: 0.0) : .easeOut(duration: 0.18),
           value: isHighlighted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHighlighted ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1.5)
                // Instant fade-in (so quick taps feel snappy), longer fade-out (so the
// green dwell tracks the latched visibility period from
// GameControllerService.rawActiveExpiry).
.animation(isHighlighted ? .linear(duration: 0.0) : .easeOut(duration: 0.18),
           value: isHighlighted)
        )
        .overlay(
            // Jump-to-binding pulse: bright yellow ring that fades out
            // after the user clicks an input on the Live Visualizer.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isPulsing ? Color.yellow.opacity(0.85) : Color.clear, lineWidth: 2.5)
                .animation(.easeOut(duration: 0.6), value: isPulsing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .debugExpandOptions($showAdvanced)
        .sheet(isPresented: $showDeadzoneCalibration) {
            DeadzoneCalibrationView(
                axisIndex: binding.input.index,
                deadzone: deadzoneCalibrationBinding,
                outerDeadzone: outerDeadzoneBinding,
                isInverted: binding.invertAxis ?? false,
                onClose: { showDeadzoneCalibration = false }
            )
            .glassBackground()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("InputConfig.ExpandBindingOptions"))) { note in
            // Tutorial / external trigger to auto-expand this row's
            // Options disclosure so the user sees what's inside
            // without having to click. Notification's object is the
            // target binding's UUID; we only react if it matches us.
            if let id = note.object as? UUID, id == binding.id {
                withAnimation(.easeInOut(duration: 0.4)) { showAdvanced = true }
            }
        }
        .onDisappear {
            // Cancel any in-flight scan when this row goes away.
            // Without this, closing the editor mid-scan leaves the
            // static timer/subscription alive; when its 5-second
            // deadline fires it writes into a `@Binding` whose source
            // is gone, routing the keypress to a stale preset draft.
            Self.cancelActiveScan()
        }
    }

    // MARK: - Per-binding note

    /// Bridges the optional `binding.note` to a non-optional String the
    /// TextField can edit. Writing an all-whitespace value clears it back to
    /// nil so empty notes don't bloat the saved preset.
    private var noteBinding: SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { binding.note ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                binding.note = trimmed.isEmpty ? nil : newValue
            }
        )
    }

    /// A subtle inline "what this does" field shown under each binding. It is
    /// always present (so any row can get a note) but stays visually quiet when
    /// empty. Smart presets pre-fill it from the profile so people can read
    /// what every control does right where it is mapped.
    /// Whether the note line shows a live text field. Collapsed rows render
    /// plain Text: AppKit text fields are the most expensive control these
    /// rows create, and materializing one per row made scrolling the binding
    /// list hitch. Clicking the note swaps the field in.
    @State private var editingNote = false
    @FocusState private var noteFieldFocused: Bool

    @ViewBuilder
    private var noteRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            if editingNote {
                TextField("Add a note (what this control does)", text: noteBinding)
                    .textFieldStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle((binding.note?.isEmpty ?? true) ? .tertiary : .secondary)
                    .lineLimit(1)
                    .focused($noteFieldFocused)
                    .onSubmit { editingNote = false }
                    .onChange(of: noteFieldFocused) { _, focused in
                        if !focused { editingNote = false }
                    }
            } else {
                Button {
                    editingNote = true
                    DispatchQueue.main.async { noteFieldFocused = true }
                } label: {
                    Text((binding.note?.isEmpty ?? true)
                         ? "Add a note (what this control does)"
                         : (binding.note ?? ""))
                        .font(.caption2)
                        .foregroundStyle((binding.note?.isEmpty ?? true) ? .tertiary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Note")
                .accessibilityValue((binding.note?.isEmpty ?? true) ? "empty" : (binding.note ?? ""))
                .accessibilityHint("Edit the note for this binding")
            }
        }
        .padding(.leading, dragWidth + colGap)
        .padding(.top, 3)
    }

    // MARK: - Index Picker (fixed width)

    @ViewBuilder
    private var indexPicker: some View {
        switch binding.input.type {
        case .button:
            // Three sections in priority order:
            // 1. "This Controller" - dynamically discovered extras
            //    (paddles, FN, mute, Home, touchpad) for the slot's
            //    connected controller. Lets users pick by physical
            //    name instead of guessing the index.
            // 2. "Standard" - canonical MFi labels for the well-known
            //    button indices (A/B/X/Y, LB/RB, Start/Back/Home...).
            // 3. "All Indices" - generic Button 0-63 fallback.
            Menu {
                if !extraButtons.isEmpty {
                    Section("This Controller") {
                        // extraButtonsSnapshot already returns the array sorted
                        // by index, so iterate it directly instead of re-sorting
                        // on every row render.
                        ForEach(extraButtons) { extra in
                            Button("\(extra.label) (#\(extra.index))") {
                                binding.input.index = extra.index
                            }
                        }
                    }
                }
                Section("Standard") {
                    ForEach(Self.standardButtonLabels, id: \.index) { entry in
                        Button("\(entry.label) (#\(entry.index))") {
                            binding.input.index = entry.index
                        }
                    }
                }
                Section("All Indices") {
                    ForEach(0..<64, id: \.self) { i in
                        Button("Button \(i)") { binding.input.index = i }
                    }
                }
            } label: {
                menuLabel(buttonMenuLabel(for: binding.input.index))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .axis:
            Menu {
                ForEach(0..<16, id: \.self) { i in
                    Button("Axis #\(i)") { binding.input.index = i }
                }
            } label: {
                menuLabel("Axis #\(binding.input.index)")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .hat:
            Picker("", selection: $binding.input.index) {
                ForEach(0..<16, id: \.self) { i in
                    Text("Hat #\(i)").tag(i)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .touchpad:
            // Touchpad "index" represents the finger slot (0 or 1).
            Picker("", selection: touchpadFingerBinding) {
                Text("Finger 1").tag(0)
                Text("Finger 2").tag(1)
            }
            .labelsHidden()
            .controlSize(.small)

        case .motion:
            // Pick the motion channel. Menu items use the long
            // `menuDescription` ("Gyro Z (roll rate)") so users
            // recognize the axis, but the closed-button label shows
            // the short `displayName` ("Gyro Z") so it fits the
            // fixed-width index column without overlapping the next
            // column.
            Menu {
                ForEach(MotionChannel.allCases) { channel in
                    Button(channel.menuDescription) {
                        binding.input.motionChannel = channel
                    }
                }
            } label: {
                menuLabel((binding.input.motionChannel ?? .gyroY).displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .touchpadRegion:
            // Pick from defined regions by name. If none are defined yet, the
            // menu shows a hint so users know to open Calibrate Touchpad.
            Menu {
                let regions = TouchpadService.shared.allRegions()
                if regions.isEmpty {
                    Text("No regions defined")
                    Text("Open Calibrate Touchpad to add some")
                } else {
                    ForEach(regions) { region in
                        Button(region.name) {
                            binding.input.touchpadRegionID = region.id
                        }
                    }
                }
            } label: {
                menuLabel(touchpadRegionDisplayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .cursorRegion:
            // Parallel to `.touchpadRegion` but the regions are screen-space
            // zones tracked against the macOS cursor position.
            Menu {
                let regions = CursorRegionService.shared.allRegions()
                if regions.isEmpty {
                    Text("No cursor regions defined")
                } else {
                    ForEach(regions) { region in
                        Button(region.name) {
                            binding.input.cursorRegionID = region.id
                        }
                    }
                }
                Divider()
                Button("Edit Cursor Regions...") {
                    showCursorRegionsEditor = true
                }
            } label: {
                menuLabel(cursorRegionDisplayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .sheet(isPresented: $showCursorRegionsEditor) {
                CursorRegionsView()
                    .glassBackground()
            }

        case .stickRegion:
            // Parallel to `.cursorRegion` but the regions are zones in
            // the joystick stick's X/Y plane. The index field carries
            // the stick selection (0 = left, 1 = right); the picker
            // groups regions by stick so users can see both sticks'
            // regions at once.
            Menu {
                let leftRegions = StickRegionService.shared.regions(forStick: 0)
                let rightRegions = StickRegionService.shared.regions(forStick: 1)
                if leftRegions.isEmpty && rightRegions.isEmpty {
                    Text("No stick regions defined")
                } else {
                    if !leftRegions.isEmpty {
                        Section("Left Stick") {
                            ForEach(leftRegions) { region in
                                Button(region.name) {
                                    binding.input.index = 0
                                    binding.input.stickRegionID = region.id
                                }
                            }
                        }
                    }
                    if !rightRegions.isEmpty {
                        Section("Right Stick") {
                            ForEach(rightRegions) { region in
                                Button(region.name) {
                                    binding.input.index = 1
                                    binding.input.stickRegionID = region.id
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Edit Stick Regions...") {
                    showStickRegionsEditor = true
                }
            } label: {
                menuLabel(stickRegionDisplayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .sheet(isPresented: $showStickRegionsEditor) {
                StickRegionsView()
                    .glassBackground()
            }

        case .extKey:
            // HID usage code. Most users won't remember a code by number, so
            // we surface a Scan affordance: if the user clicks "Scan" the next
            // physical key press on any detected keyboard becomes the binding.
            Menu {
                Section("Common keys") {
                    ForEach(commonHIDKeys, id: \.code) { entry in
                        Button("\(entry.label) (code \(entry.code))") {
                            binding.input.index = entry.code
                        }
                    }
                }
                Section("Scan") {
                    Button("Press any key on detected keyboard…") {
                        scanForExternalKey()
                    }
                }
            } label: {
                menuLabel("Key \(binding.input.index)")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .extMouse:
            // Sub-kind: button vs motion vs scroll.
            Menu {
                ForEach(ExtMouseKind.allCases) { kind in
                    Button(kind.displayName) {
                        binding.input.extMouseKind = kind
                        // Reset the index for kinds that don't need one.
                        if kind != .button { binding.input.index = 0 }
                    }
                }
            } label: {
                menuLabel((binding.input.extMouseKind ?? .button).displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .touchpadGesture:
            // The gesture kind discriminator (two-finger tap, etc.).
            Menu {
                ForEach(TouchpadGestureKind.allCases) { kind in
                    Button(kind.displayName) {
                        binding.input.touchpadGestureKind = kind
                    }
                }
            } label: {
                menuLabel(binding.input.touchpadGestureKind?.displayName
                          ?? "Two-finger tap")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .midi:
            midiIndexPicker
        }
    }

    /// 12 most-used HID Keyboard / Keypad usage codes for the dropdown.
    private var commonHIDKeys: [(label: String, code: Int)] {
        [
            ("A", 4), ("S", 22), ("D", 7), ("W", 26),
            ("Space", 44), ("Return", 40), ("Escape", 41), ("Tab", 43),
            ("Left", 80), ("Right", 79), ("Up", 82), ("Down", 81)
        ]
    }

    /// Watches `ExternalInputDeviceService.events` for one key-down then
    /// assigns it as this binding's input. Guaranteed to cancel via a
    /// scheduled timer even if no key is ever pressed - earlier versions
    /// relied on a `Date()` check inside the sink, which only ran when
    /// the subject fired, leaking the subscription forever if nothing
    /// happened. Also single-shot: re-clicking Scan cancels the previous
    /// listener via the static reference so multiple rows can't pile up.
    private func scanForExternalKey() {
        Self.activeScanCancellable?.cancel()
        Self.activeScanCancellable = nil
        Self.activeScanTimer?.invalidate()
        Self.activeScanTimer = nil

        let svc = ExternalInputDeviceService.shared
        // Capture `binding` weakly through the binding's UUID so we don't
        // assign to a stale closure if the row's binding identity changes
        // before scan completes.
        let cancellable = svc.events.sink { event in
            if case .keyDown(let dev, let code) = event {
                DispatchQueue.main.async {
                    binding.input.index = code
                    binding.input.extDeviceID = dev
                    Self.activeScanCancellable?.cancel()
                    Self.activeScanCancellable = nil
                    Self.activeScanTimer?.invalidate()
                    Self.activeScanTimer = nil
                }
            }
        }
        Self.activeScanCancellable = cancellable

        // Hard 5-second deadline. Fires on the main run loop so it always
        // runs even if no events arrive on the subject.
        Self.activeScanTimer = Timer.scheduledTimer(withTimeInterval: 5,
                                                    repeats: false) { _ in
            Self.activeScanCancellable?.cancel()
            Self.activeScanCancellable = nil
            Self.activeScanTimer = nil
        }
    }

    /// Single global slot for the active "scan for keyboard key" listener.
    /// Static so re-clicking Scan on a different row always cancels the
    /// previous subscription instead of stacking them.
    private static var activeScanCancellable: AnyCancellable?
    private static var activeScanTimer: Timer?

    /// Cancel any in-flight external-input scan. Called from
    /// `.onDisappear` so a row that goes away mid-scan doesn't keep
    /// the static timer/subscription alive and fire its 5-second
    /// deadline writing into a now-dead `@Binding`.
    static func cancelActiveScan() {
        activeScanCancellable?.cancel()
        activeScanCancellable = nil
        activeScanTimer?.invalidate()
        activeScanTimer = nil
    }

    private var touchpadRegionDisplayName: String {
        if let id = binding.input.touchpadRegionID,
           let r = TouchpadService.shared.region(with: id) {
            return r.name
        }
        return "Pick region"
    }

    private var cursorRegionDisplayName: String {
        if let id = binding.input.cursorRegionID,
           let r = CursorRegionService.shared.region(with: id) {
            return r.name
        }
        return "Pick cursor region"
    }

    /// Canonical labels for the standard 22 MFi button slots. Surfaced
    /// in the button index picker so users see "A / Cross (#0)" instead
    /// of just "Button 0". Indices 16-21 cover DualSense Edge paddles
    /// and Function buttons.
    private static let standardButtonLabels: [(index: Int, label: String)] = [
        (0, "A / Cross"),
        (1, "B / Circle"),
        (2, "X / Square"),
        (3, "Y / Triangle"),
        (4, "LB / L1"),
        (5, "RB / R1"),
        (6, "LT / L2 (digital)"),
        (7, "RT / R2 (digital)"),
        (8, "Back / Share / Select"),
        (9, "Start / Options"),
        (10, "Home / PS / Guide"),
        (11, "L3 (left stick click)"),
        (12, "R3 (right stick click)"),
        (13, "Touchpad press"),
        (14, "Share (where exposed)"),
        (15, "Microphone / Mute"),
        (16, "Left Paddle"),
        (17, "Right Paddle"),
        (18, "Paddle 3"),
        (19, "Paddle 4"),
        (20, "FN 1 / Left Function"),
        (21, "FN 2 / Right Function"),
    ]

    /// Closed-menu label. Prefers the connected controller's named
    /// extra (e.g. "Left Paddle") for the active index, falls back to
    /// a canonical standard label, otherwise the bare "Button N".
    private func buttonMenuLabel(for index: Int) -> String {
        if let extra = extraButtons.first(where: { $0.index == index }) {
            return extra.label
        }
        if let std = Self.standardButtonLabels.first(where: { $0.index == index }) {
            return std.label
        }
        return "Button \(index)"
    }

    private var stickRegionDisplayName: String {
        if let id = binding.input.stickRegionID,
           let lookup = StickRegionService.shared.region(with: id) {
            let stick = lookup.stickIndex == 1 ? "Right" : "Left"
            return "\(stick): \(lookup.region.name)"
        }
        return "Pick stick region"
    }

    /// MIDI: the first column picks the message family and its number
    /// (note or CC). Pitch bend and aftertouch are per-channel, so they
    /// have no number and the menu collapses to just the family.
    @ViewBuilder
    private var midiIndexPicker: some View {
        Menu {
            Section("Message") {
                ForEach(MIDIInputKind.allCases) { kind in
                    Button(kind.displayName) {
                        binding.input.midiKind = kind
                        // Reset the number to something sensible for the
                        // new family so the row never shows "CC 60".
                        if kind == .note { binding.input.index = 60 }
                        else if kind == .cc { binding.input.index = 1 }
                        else { binding.input.index = 0 }
                    }
                }
            }
            let kind = binding.input.midiKind ?? .note
            if kind.usesNumber {
                Section(kind == .note ? "Note" : (kind == .cc ? "Controller" : "Program")) {
                    // Live devices make Scan the better path, so this menu
                    // stays short: common values, not all 128.
                    ForEach(Self.midiNumberChoices(for: kind), id: \.0) { pair in
                        Button(pair.1) { binding.input.index = pair.0 }
                    }
                }
            }
        } label: {
            menuChevronLabel(midiIndexLabel)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private var midiIndexLabel: String {
        let kind = binding.input.midiKind ?? .note
        switch kind {
        case .note:          return MIDIService.noteName(binding.input.index)
        case .cc:            return "CC \(binding.input.index)"
        case .programChange: return "Prog \(binding.input.index)"
        case .pitchBend:     return "Pitch Bend"
        case .aftertouch:    return "Aftertouch"
        }
    }

    /// Menu choices per message family. Notes span a usable keyboard
    /// range; CC lists the controllers people actually bind.
    private static func midiNumberChoices(for kind: MIDIInputKind) -> [(Int, String)] {
        switch kind {
        case .note:
            return (36...84).map { ($0, MIDIService.noteName($0)) }
        case .cc:
            var out = MIDIService.commonCCs.map { ($0.number, "CC \($0.number) - \($0.name)") }
            let common = Set(MIDIService.commonCCs.map(\.number))
            out += (0...127).filter { !common.contains($0) }.map { ($0, "CC \($0)") }
            return out
        case .programChange:
            return (0...127).map { ($0, "Program \($0)") }
        case .pitchBend, .aftertouch:
            return []
        }
    }

    /// MIDI: the second column picks the channel (or Any).
    @ViewBuilder
    private var midiChannelPicker: some View {
        Menu {
            Button("Any channel") { binding.input.midiChannel = nil }
            Section("Channel") {
                ForEach(1...16, id: \.self) { ch in
                    Button("Channel \(ch)") { binding.input.midiChannel = ch }
                }
            }
            // Continuous controllers can be bound as a half-axis, so
            // offer the direction alongside the channel rather than
            // adding a fourth column just for MIDI.
            if (binding.input.midiKind ?? .note).isContinuous {
                Section("Direction") {
                    ForEach(AxisDirection.allCases) { dir in
                        Button(dir.displayName) { binding.input.axisDirection = dir }
                    }
                }
            }
        } label: {
            menuChevronLabel(binding.input.midiChannel.map { "Ch \($0)" } ?? "Any ch")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    // MARK: - Index / Direction Accessibility

    /// Spoken role name for the index picker, matching whatever the closed
    /// menu is actually choosing for the current input type. VoiceOver reads
    /// this before the value so the control never announces a bare number.
    private var indexPickerAccessibilityLabel: String {
        switch binding.input.type {
        case .button: return "Button"
        case .axis: return "Axis"
        case .hat: return "Hat"
        case .touchpad: return "Finger"
        case .motion: return "Motion channel"
        case .touchpadRegion: return "Touchpad region"
        case .cursorRegion: return "Cursor region"
        case .stickRegion: return "Stick region"
        case .extKey: return "Key"
        case .extMouse: return "Mouse input"
        case .touchpadGesture: return "Gesture"
        case .midi: return "MIDI message"
        }
    }

    /// Current selection spoken as the index picker's value. Mirrors the
    /// closed-menu label text for each input type.
    private var indexPickerAccessibilityValue: String {
        switch binding.input.type {
        case .button:
            return buttonMenuLabel(for: binding.input.index)
        case .axis:
            return "Axis \(binding.input.index)"
        case .hat:
            return "Hat \(binding.input.index)"
        case .touchpad:
            return (binding.input.touchpadFinger ?? binding.input.index) == 1 ? "Finger 2" : "Finger 1"
        case .motion:
            return (binding.input.motionChannel ?? .gyroY).displayName
        case .touchpadRegion:
            return touchpadRegionDisplayName
        case .cursorRegion:
            return cursorRegionDisplayName
        case .stickRegion:
            return stickRegionDisplayName
        case .midi:
            return binding.input.displayName
        case .extKey:
            return "Key \(binding.input.index)"
        case .extMouse:
            return (binding.input.extMouseKind ?? .button).displayName
        case .touchpadGesture:
            return binding.input.touchpadGestureKind?.displayName ?? "Two-finger tap"
        }
    }

    /// Spoken role name for the direction column. Some input types host a
    /// device picker or a compound axis picker here instead of a plain
    /// direction, so the label follows what the column actually controls.
    private var directionPickerAccessibilityLabel: String {
        switch binding.input.type {
        case .extKey:
            return "Keyboard device"
        case .extMouse:
            switch binding.input.extMouseKind ?? .button {
            case .button: return "Mouse button"
            case .moveX, .moveY, .scrollX, .scrollY: return "Direction"
            case .pressure, .deepPress: return "Mouse input"
            }
        case .touchpad:
            return "Axis and direction"
        default:
            return "Direction"
        }
    }

    /// Current selection spoken as the direction column's value, matching the
    /// closed-menu label for the active input type.
    private var directionPickerAccessibilityValue: String {
        switch binding.input.type {
        case .button, .touchpadRegion, .cursorRegion, .stickRegion, .touchpadGesture:
            return "Not applicable"
        case .midi:
            return binding.input.midiChannel.map { "Channel \($0)" } ?? "Any channel"
        case .axis, .motion:
            return axisDirectionBinding.wrappedValue.displayName
        case .hat:
            return hatDirectionBinding.wrappedValue.displayName
        case .touchpad:
            let axisLabel = (binding.input.touchpadAxis ?? .x).rawValue.uppercased()
            let dirLabel = (binding.input.axisDirection ?? .positive).displayName
            return "\(axisLabel) \(dirLabel)"
        case .extKey:
            return externalDeviceLabel(kind: .keyboard)
        case .extMouse:
            switch binding.input.extMouseKind ?? .button {
            case .button: return "Button \(binding.input.index)"
            case .moveX, .moveY, .scrollX, .scrollY:
                return (binding.input.axisDirection ?? .positive).displayName
            case .pressure, .deepPress: return "Built-in trackpad"
            }
        }
    }

    // MARK: - Direction Picker (fixed width, empty for buttons)

    @ViewBuilder
    private var directionPicker: some View {
        switch binding.input.type {
        case .button:
            // Empty placeholder to keep column width consistent
            Color.clear

        case .axis:
            // Lazy Menu instead of Picker for the same scroll-perf reason
            // as the type menus: NSPopUpButtons pre-build on row creation.
            Menu {
                ForEach(AxisDirection.allCases) { dir in
                    Button(dir.displayName) { axisDirectionBinding.wrappedValue = dir }
                }
            } label: {
                menuChevronLabel(axisDirectionBinding.wrappedValue.displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

        case .hat:
            Menu {
                ForEach(HatDirection.allCases) { dir in
                    Button(dir.displayName) { hatDirectionBinding.wrappedValue = dir }
                }
            } label: {
                menuChevronLabel(hatDirectionBinding.wrappedValue.displayName)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

        case .touchpadRegion:
            // Region inputs are button-like; no direction picker needed.
            Color.clear

        case .cursorRegion:
            // Same shape as `.touchpadRegion`: button-like, no direction.
            Color.clear

        case .stickRegion:
            // Stick region also acts like a button (pressed while
            // stick is inside the rect). The stick index is carried in
            // the InputEvent's `index` field and chosen from the region
            // picker, so no direction widget is needed here either.
            Color.clear

        case .motion:
            // Motion inputs read like axes: pick + or - polarity.
            Picker("", selection: axisDirectionBinding) {
                ForEach(AxisDirection.allCases) { dir in
                    Text(dir.displayName).tag(dir)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .touchpad:
            // For touchpad, the direction picker is a compound: X/Y axis +
            // half-axis direction. We render it as a single Menu so it fits
            // in the existing column width.
            Menu {
                Section("X (left/right)") {
                    Button("X +  (right)") { setTouchpad(axis: .x, dir: .positive) }
                    Button("X \u{2212}  (left)") { setTouchpad(axis: .x, dir: .negative) }
                }
                Section("Y (up/down)") {
                    Button("Y +  (down)") { setTouchpad(axis: .y, dir: .positive) }
                    Button("Y \u{2212}  (up)")   { setTouchpad(axis: .y, dir: .negative) }
                }
            } label: {
                let axisLabel = (binding.input.touchpadAxis ?? .x).rawValue.uppercased()
                let dirLabel = (binding.input.axisDirection ?? .positive).displayName
                menuLabel("\(axisLabel) \(dirLabel)")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

        case .extKey:
            // Device picker: which specific keyboard, or "Any".
            externalDeviceMenu(kind: .keyboard)

        case .extMouse:
            // For mouse buttons, this column picks button index (1..8).
            // For motion / scroll, it picks the + / - half-axis direction
            // and shows the device picker via an inline Menu.
            switch binding.input.extMouseKind ?? .button {
            case .button:
                Menu {
                    ForEach(1..<9, id: \.self) { btn in
                        Button("Mouse button \(btn)") { binding.input.index = btn }
                    }
                    Divider()
                    Section("Device") { externalDeviceMenuItems(kind: .mouse) }
                } label: {
                    menuLabel("Btn \(binding.input.index)")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .moveX, .moveY, .scrollX, .scrollY:
                Menu {
                    Button("+") { binding.input.axisDirection = .positive }
                    Button("\u{2212}") { binding.input.axisDirection = .negative }
                    Divider()
                    Section("Device") { externalDeviceMenuItems(kind: .mouse) }
                } label: {
                    menuLabel((binding.input.axisDirection ?? .positive).displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            case .pressure, .deepPress:
                // Force Touch inputs are built-in-trackpad only: no button
                // index or direction to pick.
                Text("Built-in trackpad")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

        case .touchpadGesture:
            // Gesture bindings have no direction. Render an empty
            // spacer so the column width stays aligned with the rest
            // of the rows.
            Color.clear.frame(width: 0, height: 0)

        case .midi:
            // MIDI reuses this column for the channel (plus the
            // direction for continuous messages), so a note binding
            // reads "C3 / Any ch" across the two columns.
            midiChannelPicker
        }
    }

    /// Borderless menu for picking which detected external device this
    /// binding targets, including an "Any" sentinel. No `.fixedSize()`
    /// here on purpose: the parent HStack column width must clip the
    /// menu so a long device name (e.g. "Built-in Keyboard") doesn't
    /// run into the next picker.
    @ViewBuilder
    private func externalDeviceMenu(kind: ExternalInputDeviceService.Kind) -> some View {
        Menu {
            externalDeviceMenuItems(kind: kind)
        } label: {
            menuLabel(externalDeviceLabel(kind: kind))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    /// Computes the human label for the device-picker button. Pulled out of
    /// the `Menu`'s `label:` ViewBuilder closure because mixing assignment
    /// statements with view-builder syntax doesn't compile cleanly.
    private func externalDeviceLabel(kind: ExternalInputDeviceService.Kind) -> String {
        if let id = binding.input.extDeviceID,
           let name = ExternalInputDeviceService.shared.deviceName(for: id) {
            return name
        }
        return "Any \(kind.rawValue)"
    }

    @ViewBuilder
    private func externalDeviceMenuItems(kind: ExternalInputDeviceService.Kind) -> some View {
        Button("Any \(kind.rawValue)") {
            binding.input.extDeviceID = nil
        }
        let matching = ExternalInputDeviceService.shared.devices.filter { $0.kind == kind }
        if matching.isEmpty {
            Text("No detected devices")
        } else {
            ForEach(matching) { device in
                Button(device.productName) {
                    binding.input.extDeviceID = device.id
                }
            }
        }
    }

    private func setTouchpad(axis: TouchpadAxis, dir: AxisDirection) {
        binding.input.touchpadAxis = axis
        binding.input.axisDirection = dir
    }

    private var touchpadFingerBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.input.touchpadFinger ?? binding.input.index },
            set: { newValue in
                binding.input.touchpadFinger = newValue
                binding.input.index = newValue
            }
        )
    }

    // MARK: - Output Value Controls

    private func appActionKindBinding(at index: Int) -> SwiftUI.Binding<AppActionKind> {
        SwiftUI.Binding(
            get: {
                binding.outputs.indices.contains(index)
                    ? (binding.outputs[index].appActionKind ?? .togglePauseOutputs)
                    : .togglePauseOutputs
            },
            set: {
                guard binding.outputs.indices.contains(index) else { return }
                binding.outputs[index].appActionKind = $0
            }
        )
    }

    private func targetPresetBinding(at index: Int) -> SwiftUI.Binding<UUID?> {
        SwiftUI.Binding(
            get: { binding.outputs.indices.contains(index) ? binding.outputs[index].targetPresetID : nil },
            set: {
                guard binding.outputs.indices.contains(index) else { return }
                binding.outputs[index].targetPresetID = $0
            }
        )
    }

    private func outputTextBinding(at index: Int) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { binding.outputs.indices.contains(index) ? (binding.outputs[index].text ?? "") : "" },
            set: {
                guard binding.outputs.indices.contains(index) else { return }
                binding.outputs[index].text = $0.isEmpty ? nil : $0
            }
        )
    }

    @ViewBuilder
    private func outputValueControls(at index: Int) -> some View {
        // During an animated removal SwiftUI briefly retains the outgoing row
        // with its now-stale index; guard so `binding.outputs[index]` and the
        // per-control get closures never trap on an out-of-range index.
        if !binding.outputs.indices.contains(index) {
            EmptyView()
        } else {
            outputValueControlsBody(at: index)
        }
    }

    @ViewBuilder
    private func outputValueControlsBody(at index: Int) -> some View {
        let actionBinding = outputBinding(at: index)

        switch binding.outputs[index].type {
        case .key:
            KeyCodePicker(selectedCode: keyCodeBinding(at: index))

        case .typeText:
            TextField("Text to type", text: outputTextBinding(at: index))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 140)
                .help("Typed exactly as written when the input is pressed. Capitals, symbols, and any language work.")

        case .appAction:
            HStack(spacing: 6) {
                Picker("", selection: appActionKindBinding(at: index)) {
                    ForEach(AppActionKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 160)
                .accessibilityLabel("App action")
                if binding.outputs[index].appActionKind == .activatePreset {
                    Picker("", selection: targetPresetBinding(at: index)) {
                        Text("Choose preset...").tag(UUID?.none)
                        ForEach(availablePresets, id: \.id) { entry in
                            Text(entry.name).tag(UUID?.some(entry.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(minWidth: 130)
                    .accessibilityLabel("Target preset")
                }
            }

        case .mouseButton:
            // Lazy Menu: only builds the 32 button options when opened.
            Menu {
                ForEach(0..<32, id: \.self) { i in
                    Button(mouseButtonName(i)) {
                        binding.outputs[index].mouseButtonIndex = i
                    }
                }
            } label: {
                menuLabel(mouseButtonName(binding.outputs[index].mouseButtonIndex ?? 0))
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 120)
            .controlSize(.small)

        case .mouseMotion, .mouseWheel:
            // Compact horizontal: direction, then slider, then numeric
            // readout. The "Speed" word was previously here as a label but
            // it pushed the row over the editor's minWidth on smaller
            // windows and clipped neighbouring columns; the icon-style
            // gauge symbol now hints at what the slider controls without
            // adding meaningful width.
            HStack(spacing: 6) {
                Picker("", selection: mouseAxisDirBinding(at: index)) {
                    Text("Up").tag("1 -")
                    Text("Right").tag("0 +")
                    Text("Down").tag("1 +")
                    Text("Left").tag("0 -")
                }
                .labelsHidden()
                .frame(width: 64)
                .controlSize(.small)

                Image(systemName: "speedometer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .help("Output speed")

                ThrottledSlider(
                    value: speedBinding(at: index),
                    in: 1...50,
                    step: 1,
                    onLiveChange: { liveSpeed[index] = $0 }
                )
                    .frame(minWidth: 60, idealWidth: 90)

                TextField("", value: liveSpeedBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .controlSize(.small)
                    .multilineTextAlignment(.center)
            }

        case .mouseWheelStep:
            Picker("", selection: mouseAxisDirBinding(at: index)) {
                Text("Up").tag("1 -")
                Text("Right").tag("0 +")
                Text("Down").tag("1 +")
                Text("Left").tag("0 -")
            }
            .labelsHidden()
            .frame(width: 70)
            .controlSize(.small)

        case .midiNote:
            HStack(spacing: 6) {
                Text("Note")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // Lazy Menu so the 128 note options only build when opened.
                Menu {
                    ForEach(MIDIService.notePickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            binding.outputs[index].midiNote = entry.number
                        }
                    }
                } label: {
                    let current = binding.outputs[index].midiNote ?? 60
                    menuLabel("\(MIDIService.noteName(current)) (\(current))")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 100)
                .controlSize(.small)

                Text("Vel")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("", value: midiVelocityBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .controlSize(.small)
                    .multilineTextAlignment(.center)

                Text("Ch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
            }

        case .midiCC:
            HStack(spacing: 6) {
                Text("CC")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // Lazy Menu so the 128 CC options only build when opened.
                Menu {
                    ForEach(MIDIService.ccPickerLabels, id: \.number) { entry in
                        Button(entry.label) {
                            binding.outputs[index].midiCCNumber = entry.number
                        }
                    }
                } label: {
                    let current = binding.outputs[index].midiCCNumber ?? 1
                    let label = MIDIService.ccNameByNumber[current].map { "\(current) - \($0)" } ?? "\(current)"
                    menuLabel(label)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 160)
                .controlSize(.small)

                Text("Ch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
            }

        case .midiPitchBend:
            HStack(spacing: 6) {
                Text("Ch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
                Text("Use with a continuous axis for smooth bend.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

        case .midiProgramChange:
            HStack(spacing: 6) {
                Text("Program")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Menu {
                    ForEach(0...127, id: \.self) { p in
                        Button("\(p)") { binding.outputs[index].midiProgramNumber = p }
                    }
                } label: {
                    menuLabel("\(binding.outputs[index].midiProgramNumber ?? 0)")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 70)
                .controlSize(.small)

                Text("Ch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiChannelBinding(at: index)) {
                    ForEach(1...16, id: \.self) { c in
                        Text("\(c)").tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 50)
                .controlSize(.small)
            }

        case .midiTransport:
            HStack(spacing: 6) {
                Text("Action")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: midiTransportBinding(at: index)) {
                    ForEach(MIDITransport.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                .controlSize(.small)
                Text("Sends a real-time transport message to the DAW.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Secondary Outputs

    @ViewBuilder
    private var secondaryOutputRows: some View {
        if binding.outputs.count > 1 {
            ForEach(Array(binding.outputs.enumerated().dropFirst()), id: \.element.id) { index, output in
                secondaryOutputRow(index: index, output: output)
            }
        }
    }

    private func secondaryOutputRow(index: Int, output: OutputAction) -> some View {
        HStack(spacing: colGap) {
            Color.clear.frame(width: inputColumnsWidth)

            Text("+")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            HStack(spacing: 4) {
                Image(systemName: outputIcon(for: output))
                    .font(.caption)
                    .foregroundStyle(outputColor(for: output))
                    .frame(width: 14)

                Menu {
                    outputTypeMenuItems { outputTypeBinding(at: index).wrappedValue = $0 }
                } label: {
                    menuChevronLabel(binding.outputs.indices.contains(index)
                                     ? binding.outputs[index].type.displayName
                                     : OutputType.key.displayName)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .accessibilityLabel("Output type")
                .accessibilityValue(binding.outputs.indices.contains(index)
                                    ? binding.outputs[index].type.displayName
                                    : OutputType.key.displayName)
            }
            .frame(width: outTypeColWidth, alignment: .leading)

            outputValueControls(at: index)

            Button {
                removeOutput(at: index)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove this output")

            Spacer(minLength: 4)
        }
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showAdvanced {
                advancedOptionsRow
                    .padding(.top, 6)
            }

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                        Text("Options")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(hasAdvancedOptions ? Color.blue : Color.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                // Collapsed summary of WHICH options are set, replacing the
                // old bare asterisk that said only that something was.
                if !showAdvanced && hasAdvancedOptions {
                    Text(advancedOptionsSummary)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Advanced Options

    private var hasAdvancedOptions: Bool {
        binding.deadzone != nil || binding.invertAxis == true ||
        binding.toggleMode == true || binding.turboEnabled == true ||
        binding.sensitivityCurve != nil || (binding.repeatCount ?? 1) > 1 ||
        (binding.macroSteps?.isEmpty == false) ||
        binding.variableSensitivity != nil ||
        binding.holdOutputs != nil || binding.doubleTapOutputs != nil ||
        binding.hapticEnabled == true || binding.speechEnabled == true
    }

    /// One-line summary of the configured advanced options, shown next to
    /// the collapsed disclosure. Built from the same fields
    /// `hasAdvancedOptions` checks.
    private var advancedOptionsSummary: String {
        var parts: [String] = []
        if let dz = binding.deadzone { parts.append("Deadzone \(Int(dz * 100))%") }
        if binding.invertAxis == true { parts.append("Inverted") }
        if let curve = binding.sensitivityCurve, curve != .linear {
            parts.append(curve == .exponential ? "Smooth curve" : "Aggressive curve")
        }
        if binding.variableSensitivity == true { parts.append("Variable") }
        if binding.toggleMode == true { parts.append("Toggle") }
        if binding.turboEnabled == true { parts.append("Turbo \(binding.turboRate ?? 10)/s") }
        if (binding.repeatCount ?? 1) > 1 { parts.append("Repeat x\(binding.repeatCount ?? 1)") }
        if let steps = binding.macroSteps, !steps.isEmpty {
            parts.append("Macro \(steps.count) \(steps.count == 1 ? "step" : "steps")")
        }
        if let hold = binding.holdOutputs?.first {
            parts.append("Hold \(hold.displayName)")
        }
        if let double = binding.doubleTapOutputs?.first {
            parts.append("2x \(double.displayName)")
        }
        if binding.hapticEnabled == true { parts.append("Vibrate") }
        if binding.speechEnabled == true { parts.append("Speak") }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var advancedOptionsRow: some View {
        // Vertical list. One option per line keeps the row readable and
        // matches the way the macro toggle now behaves.
        VStack(alignment: .leading, spacing: 4) {
            // The engine applies deadzone and invert to touchpad, motion,
            // and stick-region bindings too, not just axes; gating this on
            // .axis left gyro users fighting drift with no per-binding
            // deadzone UI at all. Calibrate / Curve / Variable inside stay
            // axis-only since the engine only applies them on axis paths.
            if [.axis, .touchpad, .motion, .stickRegion].contains(binding.input.type) {
                optionsGroupHeader("Stick & Trigger")
                advancedAxisOptions
            }
            optionsGroupHeader("Press Behavior")
            advancedModeOptions
            tapHoldOptions
            optionsGroupHeader("Feedback")
            advancedFeedbackOptions

            if binding.speechEnabled == true {
                speechDetailRow
            }

            // Visible whenever a macro EXISTS, not only while building one,
            // so a saved macro's steps can be reviewed and edited after
            // reopening the preset.
            if showMacroEditor || binding.macroSteps?.isEmpty == false {
                macroEditorSection
            }
        }
        .padding(.leading, dragWidth + colGap)
    }

    @ViewBuilder
    private var advancedFeedbackOptions: some View {
        // Haptic toggle
        Toggle(isOn: hapticBinding) {
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.system(size: 8))
                Text("Vibrate")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .help("Vibrate the controller when this binding fires (DualSense, DualSense Edge, and similar).")

        if binding.hapticEnabled == true {
            HStack(spacing: 4) {
                Text("Strength")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                ThrottledSlider(
                    value: hapticIntensityBinding,
                    in: 0.1...1.0,
                    step: 0.05,
                    onLiveChange: { liveHaptic = $0 }
                )
                    .frame(width: 60)
                Text(String(format: "%.0f%%", (liveHaptic ?? Double(binding.hapticIntensity ?? 0.6)) * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30)
            }
        }

        // Speech toggle
        Toggle(isOn: speechBinding) {
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 8))
                Text("Speak")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .help("Speak a phrase out loud when this binding fires.")
    }

    @ViewBuilder
    private var speechDetailRow: some View {
        HStack(spacing: 10) {
            Text("Phrase")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("Phrase to speak", text: speechTextBinding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .frame(maxWidth: 200)

            Text("Output")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Picker("", selection: speechDestinationBinding) {
                Text("Mac").tag(SpeechDestination.mac)
                Text("Controller").tag(SpeechDestination.controller)
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 110)
            Spacer()
        }
    }

    /// Output-type menu grouped Keyboard / Mouse / MIDI / App, so keyboard-
    /// and-mouse users stop wading through DAW terminology on every choice.
    /// Shared by the primary and secondary output menus; built lazily on
    /// open like KeyCodePicker, so rows render without pre-building it.
    @ViewBuilder
    private func outputTypeMenuItems(select: @escaping (OutputType) -> Void) -> some View {
        Section("Keyboard") {
            Button(OutputType.key.displayName) { select(.key) }
            Button(OutputType.typeText.displayName) { select(.typeText) }
        }
        Section("Mouse") {
            Button(OutputType.mouseButton.displayName) { select(.mouseButton) }
            Button(OutputType.mouseMotion.displayName) { select(.mouseMotion) }
            Button(OutputType.mouseWheel.displayName) { select(.mouseWheel) }
            Button(OutputType.mouseWheelStep.displayName) { select(.mouseWheelStep) }
        }
        Section("MIDI") {
            Button(OutputType.midiNote.displayName) { select(.midiNote) }
            Button(OutputType.midiCC.displayName) { select(.midiCC) }
            Button(OutputType.midiPitchBend.displayName) { select(.midiPitchBend) }
            Button(OutputType.midiProgramChange.displayName) { select(.midiProgramChange) }
            Button(OutputType.midiTransport.displayName) { select(.midiTransport) }
        }
        Section("App") {
            Button(OutputType.appAction.displayName) { select(.appAction) }
        }
    }

    /// Selects an input type from the lazy type menu.
    private func inputTypeChoice(_ type: InputType) -> some View {
        Button(type.displayName) { binding.input.type = type }
    }

    /// Shared label style for the lazy menus, matching KeyCodePicker.
    private func menuChevronLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }

    /// Tap-vs-hold and double-tap rows. Both multiply what one input can do:
    /// quick tap fires the normal outputs, a long hold (or a second tap) fires
    /// a separate keyboard key. Disabled while a macro owns the binding, since
    /// the engine gives macros precedence.
    @ViewBuilder
    private var tapHoldOptions: some View {
        let macroOwned = binding.macroSteps?.isEmpty == false
        HStack(spacing: 6) {
            Toggle(isOn: holdEnabledBinding) {
                Text("Hold action")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .help("Quick tap fires the normal output; holding past the threshold fires this key instead (tap = jump, hold = sprint).")
            if binding.holdOutputs != nil {
                KeyCodePicker(selectedCode: holdKeyBinding)
                    .frame(width: 90)
                Text("after")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                TextField("", value: holdThresholdBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(macroOwned)

        HStack(spacing: 6) {
            Toggle(isOn: doubleTapEnabledBinding) {
                Text("Double-tap action")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .help("Two taps inside the window fire this key; a single tap fires the normal output once the window lapses.")
            if binding.doubleTapOutputs != nil {
                KeyCodePicker(selectedCode: doubleTapKeyBinding)
                    .frame(width: 90)
                Text("within")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                TextField("", value: doubleTapWindowBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(macroOwned)
    }

    private var holdEnabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.holdOutputs != nil },
            set: { on in
                if on {
                    binding.holdOutputs = [OutputAction(type: .key, keyCode: 225)]
                } else {
                    binding.holdOutputs = nil
                    binding.holdThresholdMs = nil
                }
            }
        )
    }

    private var holdKeyBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.holdOutputs?.first?.keyCode ?? 225 },
            set: { binding.holdOutputs = [OutputAction(type: .key, keyCode: $0)] }
        )
    }

    private var holdThresholdBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.holdThresholdMs ?? 300 },
            set: { binding.holdThresholdMs = max(50, min(5000, $0)) }
        )
    }

    private var doubleTapEnabledBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.doubleTapOutputs != nil },
            set: { on in
                if on {
                    binding.doubleTapOutputs = [OutputAction(type: .key, keyCode: 4)]
                } else {
                    binding.doubleTapOutputs = nil
                    binding.doubleTapWindowMs = nil
                }
            }
        )
    }

    private var doubleTapKeyBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.doubleTapOutputs?.first?.keyCode ?? 4 },
            set: { binding.doubleTapOutputs = [OutputAction(type: .key, keyCode: $0)] }
        )
    }

    private var doubleTapWindowBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.doubleTapWindowMs ?? 300 },
            set: { binding.doubleTapWindowMs = max(100, min(2000, $0)) }
        )
    }

    /// Arrow between the input and output columns. While the row is firing
    /// it tints green and sweeps left to right (a repeating "shoot" toward
    /// the output side), then settles back when the input releases. The
    /// animation is Core Animation driven, so it costs no per-frame SwiftUI
    /// body work.
    private var firingArrow: some View {
        Image(systemName: "arrow.right")
            .font(.caption)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
            // Static when Reduce Motion is on; the green tint alone signals firing.
            .offset(x: reduceMotion ? 0 : (arrowShoot ? 5 : -5))
            .animation(reduceMotion
                       ? nil
                       : arrowShoot
                       ? Animation.easeIn(duration: 0.3).repeatForever(autoreverses: false)
                       : Animation.easeOut(duration: 0.15),
                       value: arrowShoot)
            .frame(width: arrowWidth)
            .accessibilityHidden(true)
            .onChange(of: isHighlighted) { _, firing in
                arrowShoot = reduceMotion ? false : firing
            }
    }

    private func optionsGroupHeader(_ title: String) -> some View {
        // A hairline + breathing room above each group so the expanded
        // Options list reads as labelled clusters instead of one wall.
        VStack(alignment: .leading, spacing: 3) {
            Divider()
                .opacity(0.5)
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 6)
        .padding(.bottom, 1)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var advancedAxisOptions: some View {
        // Deadzone
        HStack(spacing: 4) {
            Text("Deadzone")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ThrottledSlider(
                value: deadzoneBinding,
                in: 0.01...0.9,
                step: 0.01,
                onLiveChange: { liveDeadzone = $0 }
            )
                .frame(width: 70)
            let dzPct = String(format: "%.0f%%", (liveDeadzone ?? Double(binding.deadzone ?? 0.25)) * 100)
            Text(dzPct)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30)
            // Visible "Calibrate" button, axis bindings only (the
            // calibration view samples stick / trigger axes). The icon
            // differs for triggers (1D pressure gauge) vs joysticks
            // (2D circle) so the user can tell at a glance which kind
            // of input this binding uses.
            if binding.input.type == .axis {
                Button {
                    showDeadzoneCalibration = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isTriggerAxis ? "gauge.with.dots.needle.50percent" : "dot.circle.and.hand.point.up.left.fill")
                            .font(.system(size: 9))
                        Text("Calibrate")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.solidSecondaryMini)
                .help(isTriggerAxis
                      ? "Open the trigger pressure calibration view."
                      : "Calibrate the joystick by moving it around in a circle.")
            }
        }

        // Invert
        Toggle(isOn: invertBinding) {
            Text("Invert")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)

        // Curve and Variable apply only on the engine's axis paths.
        if binding.input.type == .axis {
            // Curve
            HStack(spacing: 4) {
                Text("Curve")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Picker("", selection: curveBinding) {
                    Text("Linear").tag(SensitivityCurve.linear)
                    Text("Smooth").tag(SensitivityCurve.exponential)
                    Text("Aggressive").tag(SensitivityCurve.aggressive)
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 80)
            }

            // Variable Sensitivity (scale output by axis depth)
            Toggle(isOn: variableSensitivityBinding) {
                Text("Variable")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .help("Scale output speed by how far the joystick or trigger is pushed.")
        }
    }

    @ViewBuilder
    private var advancedModeOptions: some View {
        Toggle(isOn: toggleBinding) {
            Text("Toggle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)

        Toggle(isOn: turboBinding) {
            Text("Turbo")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)

        if binding.turboEnabled == true {
            HStack(spacing: 3) {
                TextField("", value: turboRateBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 36)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("/s")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }

        // Repeat count
        HStack(spacing: 3) {
            Text("Repeat")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("", value: repeatCountBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 36)
                .controlSize(.mini)
                .multilineTextAlignment(.center)
            Text("×")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }

        if (binding.repeatCount ?? 1) > 1 {
            HStack(spacing: 3) {
                Text("Delay")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TextField("", value: repeatDelayBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }

        // Macro toggle - opens the macro editor below the row when on.
        // Matches the visual style of the other toggles in this section.
        Toggle(isOn: macroToggleBinding) {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                Text("Macro")
                    .font(.system(size: 9))
            }
            .foregroundStyle(binding.macroSteps?.isEmpty == false ? Color.orange : .secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
    }

    /// Reflects the binding's ACTUAL macro state, not just editor
    /// visibility. The old bridge read a transient @State, so reopening a
    /// preset showed an unchecked box while a saved macro silently
    /// overrode the row's outputs, and unchecking did not disable it.
    /// Turning it on opens the step editor; turning it off removes the
    /// macro (recoverable with Undo, which restores the whole binding).
    private var macroToggleBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.macroSteps?.isEmpty == false || showMacroEditor },
            set: { on in
                if on {
                    showMacroEditor = true
                } else {
                    binding.macroSteps = nil
                    showMacroEditor = false
                }
            }
        )
    }

    // MARK: - Advanced Bindings

    private var deadzoneBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.deadzone ?? 0.25) },
            set: { binding.deadzone = Float($0) }
        )
    }

    /// Triggers live on axis indices 4 (left) and 5 (right) by convention.
    /// Used to switch the Calibrate button icon between trigger gauge and
    /// joystick circle styles.
    private var isTriggerAxis: Bool {
        binding.input.type == .axis && (binding.input.index == 4 || binding.input.index == 5)
    }

    /// Like `deadzoneBinding` but always writes the value (even the 0.25 default).
    /// The calibration view always wants to persist what the user picked so the
    /// next time they open the editor the slider matches what they set.
    private var deadzoneCalibrationBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.deadzone ?? 0.25) },
            set: { binding.deadzone = Float($0) }
        )
    }

    /// Outer deadzone binding for the calibration sheet. Defaults to 1.0
    /// (no saturation), which the view interprets as "no outer ring".
    private var outerDeadzoneBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.outerDeadzone ?? 1.0) },
            set: { binding.outerDeadzone = $0 >= 0.99 ? nil : Float($0) }
        )
    }

    private var invertBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.invertAxis ?? false },
            set: { binding.invertAxis = $0 ? true : nil }
        )
    }

    private var toggleBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.toggleMode ?? false },
            set: {
                binding.toggleMode = $0 ? true : nil
                if $0 { binding.turboEnabled = nil } // Mutually exclusive
            }
        )
    }

    private var turboBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.turboEnabled ?? false },
            set: {
                binding.turboEnabled = $0 ? true : nil
                if $0 { binding.toggleMode = nil } // Mutually exclusive
            }
        )
    }

    private var turboRateBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.turboRate ?? 10 },
            set: { binding.turboRate = $0 }
        )
    }

    private var curveBinding: SwiftUI.Binding<SensitivityCurve> {
        SwiftUI.Binding(
            get: { binding.sensitivityCurve ?? .linear },
            set: { binding.sensitivityCurve = $0 == .linear ? nil : $0 }
        )
    }

    private var repeatCountBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.repeatCount ?? 1 },
            set: { binding.repeatCount = $0 <= 1 ? nil : max(1, min(100, $0)) }
        )
    }

    private var repeatDelayBinding: SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.repeatDelayMs ?? 100 },
            set: { binding.repeatDelayMs = max(10, min(5000, $0)) }
        )
    }

    private var variableSensitivityBinding: SwiftUI.Binding<Bool> {
        // Default: true when input is an axis (matches engine behavior), false otherwise
        let defaultValue = binding.input.type == .axis
        return SwiftUI.Binding(
            get: { binding.variableSensitivity ?? defaultValue },
            set: { binding.variableSensitivity = $0 == defaultValue ? nil : $0 }
        )
    }

    private var hapticBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.hapticEnabled ?? false },
            set: { binding.hapticEnabled = $0 ? true : nil }
        )
    }

    private var hapticIntensityBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.hapticIntensity ?? 0.6) },
            set: { binding.hapticIntensity = Float($0) }
        )
    }

    private var speechBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.speechEnabled ?? false },
            set: { binding.speechEnabled = $0 ? true : nil }
        )
    }

    private var speechTextBinding: SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: { binding.speechText ?? "" },
            set: { binding.speechText = $0.isEmpty ? nil : $0 }
        )
    }

    private var speechDestinationBinding: SwiftUI.Binding<SpeechDestination> {
        SwiftUI.Binding(
            get: { binding.speechDestination ?? .mac },
            set: { binding.speechDestination = $0 == .mac ? nil : $0 }
        )
    }

    // MARK: - Macro Editor

    private var macroEditorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Macro Sequence")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: macroStopOnReleaseBinding) {
                    Text("Stop on release")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .help("Letting go of the input stops the rest of the sequence and releases any held steps.")
                Button {
                    var steps = binding.macroSteps ?? []
                    steps.append(MacroStep(action: OutputAction(type: .key, keyCode: 4)))
                    binding.macroSteps = steps
                } label: {
                    Label("Add Step", systemImage: "plus.circle")
                        .font(.system(size: 9))
                }
                .buttonStyle(.solidSecondaryMini)
            }

            if let steps = binding.macroSteps, !steps.isEmpty {
                macroStepsList(steps)
            } else {
                Text("No steps. Add steps to create a macro sequence that fires on press.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Text("Macros override normal outputs. Steps fire in sequence; a Hold down step keeps its key held while the following steps run (for chords like Cmd+C), and Release lets it go.")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.04)))
    }

    private func macroStepsList(_ steps: [MacroStep]) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                macroStepRow(index: index, step: step)
            }
        }
    }

    private func macroStepRow(index: Int, step: MacroStep) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1).")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 18)

            Picker("", selection: macroStepKindBinding(at: index)) {
                ForEach(MacroStepKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 84)
            .help("Tap presses and releases. Hold down keeps the key held while later steps run (for chords like Cmd+C). Release lets go of a held key.")

            Picker("", selection: macroStepTypeBinding(at: index)) {
                // Only the step types with working parameter editors. The
                // full OutputType list offered Mouse Motion / Wheel steps
                // that fired as silent no-ops and MIDI steps locked to
                // hardcoded defaults; more types can return as they gain
                // per-step editors.
                Text(OutputType.key.displayName).tag(OutputType.key)
                Text(OutputType.mouseButton.displayName).tag(OutputType.mouseButton)
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 100)

            if step.action.type == .key {
                KeyCodePicker(selectedCode: macroStepKeyBinding(at: index))
                    .frame(width: 90)
            } else if step.action.type == .mouseButton {
                Picker("", selection: macroStepMouseBtnBinding(at: index)) {
                    ForEach(0..<6, id: \.self) { i in
                        Text(mouseButtonName(i)).tag(i)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 90)
            }

            HStack(spacing: 2) {
                Text("Wait")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                TextField("", value: macroDelayBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 36)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 2) {
                Text("Hold")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                TextField("", value: macroHoldBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 36)
                    .controlSize(.mini)
                    .multilineTextAlignment(.center)
                Text("ms")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 2) {
                Button { moveMacroStep(at: index, by: -1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .help("Move step up")
                .accessibilityLabel("Move step up")

                Button { moveMacroStep(at: index, by: 1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .buttonStyle(.plain)
                .disabled(index >= (binding.macroSteps?.count ?? 0) - 1)
                .help("Move step down")
                .accessibilityLabel("Move step down")

                Button { duplicateMacroStep(at: index) } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 8))
                }
                .buttonStyle(.plain)
                .help("Duplicate step")
                .accessibilityLabel("Duplicate step")
            }
            .foregroundStyle(.secondary)

            Button {
                var steps = binding.macroSteps ?? []
                guard index < steps.count else { return }
                steps.remove(at: index)
                binding.macroSteps = steps.isEmpty ? nil : steps
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove this macro step")

            Spacer()
        }
    }

    private func moveMacroStep(at index: Int, by offset: Int) {
        guard var steps = binding.macroSteps else { return }
        let target = index + offset
        guard steps.indices.contains(index), steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
        binding.macroSteps = steps
    }

    private func duplicateMacroStep(at index: Int) {
        guard var steps = binding.macroSteps, steps.indices.contains(index) else { return }
        let src = steps[index]
        let copy = MacroStep(action: src.action, delayMs: src.delayMs, holdMs: src.holdMs,
                             eventKind: src.eventKind)
        steps.insert(copy, at: index + 1)
        binding.macroSteps = steps
    }

    // MARK: - Macro Bindings

    private var macroStopOnReleaseBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { binding.macroInterruptOnRelease ?? false },
            set: { binding.macroInterruptOnRelease = $0 ? true : nil }
        )
    }

    private func macroStepKindBinding(at index: Int) -> SwiftUI.Binding<MacroStepKind> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].eventKind ?? .tap },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].eventKind = ($0 == .tap) ? nil : $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepTypeBinding(at index: Int) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].action.type ?? .key },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.type = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepKeyBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].action.keyCode ?? 4 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.keyCode = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroStepMouseBtnBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].action.mouseButtonIndex ?? 0 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].action.mouseButtonIndex = $0
                binding.macroSteps = steps
            }
        )
    }

    private func macroDelayBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].delayMs ?? 50 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].delayMs = max(0, min(10000, $0))
                binding.macroSteps = steps
            }
        )
    }

    private func macroHoldBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.macroSteps?[index].holdMs ?? 50 },
            set: {
                guard var steps = binding.macroSteps, index < steps.count else { return }
                steps[index].holdMs = max(0, min(10000, $0))
                binding.macroSteps = steps
            }
        )
    }

    // MARK: - Helpers

    /// Compact label used by Menu-style controls so they look like Pickers
    /// but with lazy contents. Shows the current value and a chevron.
    @ViewBuilder
    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
    }

    private func outputIcon(for action: OutputAction) -> String {
        switch action.type {
        case .key: return "keyboard"
        case .typeText: return "text.cursor"
        case .appAction: return "arrow.triangle.2.circlepath"
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep: return "computermouse"
        case .midiNote: return "music.note"
        case .midiCC: return "slider.horizontal.3"
        case .midiPitchBend: return "waveform.path"
        case .midiProgramChange: return "guitars"
        case .midiTransport: return "playpause"
        }
    }

    private func outputColor(for action: OutputAction) -> Color {
        switch action.type {
        case .key, .typeText: return .orange
        case .appAction: return .teal
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep: return .purple
        case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport: return .pink
        }
    }

    private func mouseButtonName(_ index: Int) -> String {
        switch index {
        case 0: return "0 - Main Click"
        case 1: return "1 - Secondary"
        case 2: return "2 - Middle"
        case 3: return "3 - Back"
        case 4: return "4 - Forward"
        case 5: return "5 - Extra"
        default: return "\(index)"
        }
    }

    // MARK: - Bindings

    private var axisDirectionBinding: SwiftUI.Binding<AxisDirection> {
        SwiftUI.Binding(
            get: { binding.input.axisDirection ?? .positive },
            set: { binding.input.axisDirection = $0 }
        )
    }

    private var hatDirectionBinding: SwiftUI.Binding<HatDirection> {
        SwiftUI.Binding(
            get: { binding.input.hatDirection ?? .up },
            set: { binding.input.hatDirection = $0 }
        )
    }

    private var firstOutputTypeBinding: SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.outputs.first?.type ?? .key },
            set: { binding.outputs[0].type = $0 }
        )
    }

    private func outputBinding(at index: Int) -> SwiftUI.Binding<OutputAction> {
        SwiftUI.Binding(
            get: { binding.outputs[index] },
            set: { binding.outputs[index] = $0 }
        )
    }

    private func outputTypeBinding(at index: Int) -> SwiftUI.Binding<OutputType> {
        SwiftUI.Binding(
            get: { binding.outputs[index].type },
            set: { binding.outputs[index].type = $0 }
        )
    }

    private func keyCodeBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].keyCode ?? 4 },
            set: { binding.outputs[index].keyCode = $0 }
        )
    }

    private func mouseAxisDirBinding(at index: Int) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(
            get: {
                let axis = binding.outputs[index].mouseAxis?.rawValue ?? 1
                let dir = binding.outputs[index].mouseDirection?.rawValue ?? "-"
                return "\(axis) \(dir)"
            },
            set: { newValue in
                let parts = newValue.split(separator: " ")
                if parts.count >= 2,
                   let axisVal = Int(parts[0]),
                   let axis = MouseAxis(rawValue: axisVal) {
                    binding.outputs[index].mouseAxis = axis
                    binding.outputs[index].mouseDirection = MouseDirection(rawValue: String(parts[1]))
                }
            }
        )
    }

    private func speedBinding(at index: Int) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.outputs[index].speed ?? 6) },
            set: { binding.outputs[index].speed = Int($0) }
        )
    }

    /// TextField binding that reads from the live drag mirror so the box
    /// updates while the user is sliding, and writes go to both the mirror
    /// and the underlying preset (so typing into the field still works).
    private func liveSpeedBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: {
                if let live = liveSpeed[index] { return Int(live) }
                return binding.outputs[index].speed ?? 6
            },
            set: { newValue in
                let clamped = max(1, min(50, newValue))
                binding.outputs[index].speed = clamped
                liveSpeed[index] = Double(clamped)
            }
        )
    }

    // MARK: - MIDI Bindings

    private func midiVelocityBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiVelocity ?? 100 },
            set: { binding.outputs[index].midiVelocity = max(0, min(127, $0)) }
        )
    }

    private func midiChannelBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiChannel ?? 1 },
            set: { binding.outputs[index].midiChannel = max(1, min(16, $0)) }
        )
    }

    private func midiTransportBinding(at index: Int) -> SwiftUI.Binding<MIDITransport> {
        SwiftUI.Binding(
            get: { binding.outputs[index].midiTransport ?? .start },
            set: { binding.outputs[index].midiTransport = $0 }
        )
    }

    private func removeOutput(at index: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            binding.outputs.remove(at: index)
        }
    }
}
