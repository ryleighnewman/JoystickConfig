import SwiftUI

/// Full-featured preset editor with joystick groups and bindings.
/// Shows live input highlighting via mappingEngine environment object.
struct PresetEditorView: View {
    @State var preset: Preset
    let onSave: (Preset) -> Void

    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine
    @Environment(\.dismiss) private var dismiss

    @State private var scanningBinding: (joystickIndex: Int, bindingIndex: Int)?
    @State private var showingScanOverlay = false
    @State private var preSortSnapshot: [JoystickMapping]?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    headerSection

                    Divider()

                    ForEach(Array(preset.joysticks.enumerated()), id: \.element.id) { index, joystick in
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
                            onRemoveJoystick: { removeJoystick(at: index) }
                        )
                        .environmentObject(mappingEngine)
                    }

                    Button {
                        withAnimation {
                            preset.joysticks.append(JoystickMapping(tag: "<write comments here>"))
                        }
                    } label: {
                        Label("Add a new Joystick", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                                    .foregroundStyle(.green.opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .navigationTitle("Edit Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(preset)
                        dismiss()
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
        }
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
            }
            HStack {
                Text("Tag:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                TextField("Tag / Description", text: $preset.tag)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Binding Helpers

    private func binding(for joystickIndex: Int) -> SwiftUI.Binding<JoystickMapping> {
        SwiftUI.Binding(
            get: { preset.joysticks[joystickIndex] },
            set: { preset.joysticks[joystickIndex] = $0 }
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
            let clone = BindingModel(input: original.input, outputs: original.outputs)
            preset.joysticks[joystickIndex].bindings.insert(clone, at: bindingIndex + 1)
        }
    }

    private func sortBindings(in joystickIndex: Int) {
        withAnimation {
            preset.joysticks[joystickIndex].bindings.sort { a, b in
                let typeOrder: [InputType: Int] = [.button: 0, .axis: 1, .hat: 2]
                let aType = typeOrder[a.input.type] ?? 0
                let bType = typeOrder[b.input.type] ?? 0
                if aType != bType { return aType < bType }
                return a.input.index < b.input.index
            }
        }
    }

    private func duplicateJoystick(at index: Int) {
        withAnimation {
            var clone = preset.joysticks[index]
            clone = JoystickMapping(
                tag: clone.tag,
                bindings: clone.bindings.map { b in
                    BindingModel(input: b.input, outputs: b.outputs)
                }
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
        scanningBinding = (joystickIndex, bindingIndex)
        showingScanOverlay = true
        controllerService.startScanning { event in
            // Input received - handled in handleScannedInput
        }
    }

    private func handleScannedInput(_ event: InputEvent) {
        guard let scanning = scanningBinding else { return }
        preset.joysticks[scanning.joystickIndex].bindings[scanning.bindingIndex].input = event
        showingScanOverlay = false
        controllerService.stopScanning()
        scanningBinding = nil
    }
}

// Helper extension for inserting after an index
private extension Array {
    mutating func insert(_ element: Element, after index: Int) {
        let insertIndex = Swift.min(index + 1, count)
        insert(element, at: insertIndex)
    }
}
