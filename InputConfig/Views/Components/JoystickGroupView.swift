import SwiftUI

/// A joystick group showing its header and list of bindings.
/// Observes mappingEngine directly so highlight state updates in real-time.
struct JoystickGroupView: View {
    @SwiftUI.Binding var joystick: JoystickMapping
    let joystickIndex: Int
    let controllerName: String
    let onAddBinding: () -> Void
    let onRemoveBinding: (Int) -> Void
    let onDuplicateBinding: (Int) -> Void
    let onScanInput: (Int) -> Void
    let onSortBindings: () -> Void
    let onDuplicate: () -> Void
    let onRemoveJoystick: () -> Void
    /// Binding UUID currently pulsing (jump-to-binding from Live Visualizer).
    /// nil when no pulse is active.
    var pulsingBindingID: UUID? = nil

    /// Preset list for the App Action target picker, passed as plain values
    /// so the row views stay store-subscription free.
    var availablePresets: [(id: UUID, name: String)] = []

    @EnvironmentObject var mappingEngine: MappingEngine
    @EnvironmentObject var controllerService: GameControllerService
    @ObservedObject private var rawHIDService = RawHIDGamepadService.shared
    @ObservedObject private var externalInput = ExternalInputDeviceService.shared
    @State private var preSortSnapshot: [BindingModel]?
    /// Inline rename popover state for the "Custom name..." menu item.
    @State private var renamePopoverOpen: Bool = false
    @State private var renameDraft: String = ""
    /// Stick Settings popover: set the deadzone across every axis binding
    /// in this joystick in one move instead of expanding each row's Options.
    @State private var showStickSettings = false
    @State private var bulkDeadzone: Double = 0.25

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if joystick.isExpanded {
                // Compute the per-slot extras snapshot ONCE per render and reuse
                // it for every row. extraButtonsSnapshot maps + sorts cached data
                // under a lock, so calling it once per binding row turned the
                // editor render into an O(rows) hot path (the biggest UI-lag
                // contributor while a preset with many binds is open).
                let extras = controllerService.extraButtonsSnapshot(for: joystickIndex)
                // Rows never display press state, but `pressed` participates
                // in ExtraButton's Equatable, so passing the live snapshot
                // re-rendered every picker-heavy row each time any extra
                // button changed state. Strip it so the rows diff stably;
                // this was the main scroll-lag source while a controller
                // was connected.
                let rowExtras = extras.map {
                    GameControllerService.ExtraButton(label: $0.label, index: $0.index, pressed: false)
                }
                // Use `bindings.indices` instead of `Array(...).enumerated()`
                // to avoid allocating a new array on every render.
                // Plain VStack on purpose: lazy rows re-triggered heavy
                // layout bursts under rapid page-down scrolling. Eager rows
                // measured freeze-proof and CPU-idle during wheel scrolling.
                VStack(spacing: 2) {
                    ForEach(joystick.bindings.indices, id: \.self) { index in
                        let binding = joystick.bindings[index]
                        // Serialize the input once and reuse it across the three
                        // highlight membership checks (was rebuilt 3x per row).
                        let inputKey = binding.input.serialized
                        BindingRowView(
                            binding: bindingAt(index),
                            onScan: { onScanInput(index) },
                            onRemove: { onRemoveBinding(index) },
                            onDuplicate: { onDuplicateBinding(index) },
                            // Light up against raw controller state OR the
                            // engine's preset-aware set, whichever is firing.
                            // This works even with no preset active.
                            isHighlighted:
                                mappingEngine.activeInputsPublished.contains(inputKey)
                                || controllerService.rawActiveInputs.contains(inputKey)
                                || externalInput.rawActiveInputs.contains(inputKey),
                            displayNumber: index + 1,
                            isPulsing: pulsingBindingID == binding.id,
                            // Named extras (paddles/FN/mute/Home) for the
                            // slot's connected controller, passed by value so
                            // BindingRowView doesn't need to subscribe to
                            // the service itself.
                            extraButtons: rowExtras,
                            availablePresets: availablePresets
                        )
                        .id(binding.id)
                    }
                }
                .padding(.vertical, 2)
                // Suppress implicit transitions on row insertion/removal so
                // scrolling does not trigger animation work for new rows.
                .animation(nil, value: joystick.bindings.count)

                Button(action: onAddBinding) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.green)
                        Text("Add a new bind")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.green.opacity(0.03))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.25))
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { joystick.isExpanded.toggle() }
            } label: {
                Image(systemName: joystick.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    // Slot identity picker - tap to bind this slot to a
                    // specific detected device, or set a custom name.
                    // Currently this view doesn't own the assignment
                    // (slot index → device) so the picker primarily acts
                    // on the human-readable name; future work threads
                    // a real binding through, e.g. by storing the
                    // selected device's persistentIdentifier in
                    // JoystickMapping.
                    deviceMenu
                    Text("#\(joystickIndex)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(controllerName)
                        .font(.caption2)
                        .foregroundStyle(controllerName.contains("No controller") ? .red.opacity(0.6) : .secondary)
                        .lineLimit(1)
                }
                TextField("Tag / comment", text: $joystick.tag)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    preSortSnapshot = joystick.bindings
                    onSortBindings()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Sort bindings")

                if preSortSnapshot != nil {
                    Button {
                        if let snapshot = preSortSnapshot {
                            withAnimation { joystick.bindings = snapshot }
                            preSortSnapshot = nil
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Undo sort")
                }

                Button {
                    // Open on the current value: seed from the first axis
                    // binding that has an explicit deadzone set.
                    if let dz = joystick.bindings.first(where: {
                        $0.input.type == .axis && $0.deadzone != nil
                    })?.deadzone {
                        bulkDeadzone = Double(dz)
                    }
                    showStickSettings = true
                } label: {
                    Image(systemName: "dial.low")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Stick settings: set the deadzone for every axis binding at once")
                .accessibilityLabel("Stick settings")
                .accessibilityHint("Sets the deadzone for every axis binding in this joystick at once.")
                .popover(isPresented: $showStickSettings, arrowEdge: .bottom) {
                    stickSettingsPopover
                }

                CopyIconButton(action: onDuplicate,
                               helpText: "Clone this joystick group",
                               size: .caption)

                Button(action: onRemoveJoystick) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this joystick group")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
    }

    // MARK: - Stick settings (bulk deadzone)

    private var axisBindingIndices: [Int] {
        joystick.bindings.indices.filter { joystick.bindings[$0].input.type == .axis }
    }

    private var stickSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stick Settings")
                .font(.headline)
            Text("Sets the inner deadzone for every axis binding in this joystick in one move. Individual bindings can still be fine-tuned afterwards in their Options.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Slider(value: $bulkDeadzone, in: 0...0.9) {
                    Text("Deadzone")
                }
                .accessibilityValue("\(Int(bulkDeadzone * 100)) percent")
                Text("\(Int(bulkDeadzone * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            HStack {
                if axisBindingIndices.isEmpty {
                    Text("No axis bindings in this joystick yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Apply to \(axisBindingIndices.count) axis binding\(axisBindingIndices.count == 1 ? "" : "s")") {
                    for i in axisBindingIndices {
                        joystick.bindings[i].deadzone = Float(bulkDeadzone)
                    }
                    showStickSettings = false
                }
                .buttonStyle(.solidCompact)
                .disabled(axisBindingIndices.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Display name shown in the header chip. Priority:
    ///   1. user-set customName
    ///   2. controllerName (passed in by the editor - reflects the
    ///      controller actually attached to this slot)
    ///   3. fallback to "Joystick #N"
    private var resolvedHeaderName: String {
        if let custom = joystick.customName, !custom.isEmpty { return custom }
        let trimmed = controllerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !trimmed.contains("No controller") { return trimmed }
        return "Joystick #\(joystickIndex)"
    }

    /// Tap-to-pick menu replacing the previous bare TextField. Lists
    /// every input device the app knows about (GameController-framework
    /// controllers, raw HID gamepads, attached keyboards, attached
    /// mice) so the user can label this slot with the device they
    /// want it to represent. "Set custom name..." opens an inline
    /// popover with a TextField for free-form labels.
    /// Pre-computed device lists pulled out of the Menu's MenuBuilder
    /// closure. Inline `let` + `filter` chains inside @ViewBuilder /
    /// @MenuBuilder bodies stalls the Swift type-checker; computed
    /// properties give it a fixed shape to reason about.
    private var connectedControllerNames: [String] {
        controllerService.connectedControllers.map { gc in
            gc.vendorName ?? gc.productCategory
        }
    }

    private var rawHIDNames: [String] {
        rawHIDService.connectedGamepads.map(\.displayName)
    }

    private var keyboardNames: [String] {
        externalInput.devices.filter { $0.kind == .keyboard }.map(\.productName)
    }

    private var mouseNames: [String] {
        externalInput.devices.filter { $0.kind == .mouse }.map(\.productName)
    }

    @ViewBuilder
    private var deviceMenu: some View {
        Menu {
            Button("Auto-detect (\(controllerName))") {
                joystick.customName = nil
                joystick.inputKind = .auto
            }
            Divider()
            Section("Game controllers") {
                ForEach(Array(connectedControllerNames.enumerated()),
                        id: \.offset) { _, name in
                    Button(name) {
                        joystick.customName = name
                        joystick.inputKind = .controller
                    }
                }
                ForEach(Array(rawHIDNames.enumerated()),
                        id: \.offset) { _, name in
                    Button(name) {
                        joystick.customName = name
                        joystick.inputKind = .controller
                    }
                }
            }
            Section("Keyboards") {
                ForEach(Array(keyboardNames.enumerated()),
                        id: \.offset) { _, name in
                    Button(name) {
                        joystick.customName = name
                        joystick.inputKind = .keyboard
                    }
                }
            }
            Section("Mice") {
                ForEach(Array(mouseNames.enumerated()),
                        id: \.offset) { _, name in
                    Button(name) {
                        joystick.customName = name
                        joystick.inputKind = .mouse
                    }
                }
            }
            Divider()
            Button("Set custom name…") {
                renameDraft = joystick.customName ?? ""
                renamePopoverOpen = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(resolvedHeaderName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(joystick.customName == nil ? .secondary : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose a detected device or set a custom name for this slot.")
        .spotlightAnchor(SpotlightID.slotChip)
        .popover(isPresented: $renamePopoverOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Slot name")
                    .font(.headline)
                TextField("e.g. Player 1 - Steve", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                HStack {
                    Button("Cancel") { renamePopoverOpen = false }
                        .buttonStyle(.solidSecondaryCompact)
                    Spacer()
                    Button("Save") {
                        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        joystick.customName = trimmed.isEmpty ? nil : trimmed
                        renamePopoverOpen = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.solid)
                }
            }
            .padding(12)
        }
    }

    private func bindingAt(_ index: Int) -> SwiftUI.Binding<BindingModel> {
        SwiftUI.Binding(
            get: { joystick.bindings[index] },
            set: { joystick.bindings[index] = $0 }
        )
    }
}
