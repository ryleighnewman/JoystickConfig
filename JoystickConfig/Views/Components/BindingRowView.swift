import SwiftUI

/// A single binding row with fixed-width columns for consistent alignment.
struct BindingRowView: View {
    @SwiftUI.Binding var binding: BindingModel
    let onScan: () -> Void
    let onRemove: () -> Void
    var onDuplicate: (() -> Void)?
    var isHighlighted: Bool = false

    @State private var showAdvanced = false
    @State private var showMacroEditor = false

    // Fixed column widths for perfect alignment
    private let dragWidth: CGFloat = 16
    private let scanColWidth: CGFloat = 54
    private let typeColWidth: CGFloat = 78
    private let indexColWidth: CGFloat = 98
    private let dirColWidth: CGFloat = 58
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
                // Drag handle
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: dragWidth)

                // COL 1: Scan
                Button("Scan", action: onScan)
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .frame(width: scanColWidth, alignment: .center)

                // COL 2: Input Type
                Picker("", selection: $binding.input.type) {
                    ForEach(InputType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: typeColWidth, alignment: .leading)

                // COL 3: Index
                indexPicker
                    .frame(width: indexColWidth, alignment: .leading)

                // COL 4: Direction (or empty spacer for Button type)
                directionPicker
                    .frame(width: dirColWidth, alignment: .leading)

                // Arrow
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: arrowWidth)

                // COL 5: Output Type
                if !binding.outputs.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: outputIcon(for: binding.outputs[0]))
                            .font(.caption)
                            .foregroundStyle(binding.outputs[0].type == .key ? .orange : .purple)
                            .frame(width: 14)

                        Picker("", selection: firstOutputTypeBinding) {
                            ForEach(OutputType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    .frame(width: outTypeColWidth, alignment: .leading)

                    // COL 6: Output Value (flexible)
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
                    }
                }

                Spacer(minLength: 4)

                // COL 7: Actions
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

                    if let onDuplicate {
                        Button(action: onDuplicate) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Duplicate this binding")
                    }

                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.7))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: actionsWidth + 18, alignment: .trailing)
            }

            // Secondary output sub-rows
            secondaryOutputRows

            // Advanced options
            advancedSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.green.opacity(0.18) : Color.secondary.opacity(0.05))
                .animation(.easeInOut(duration: 0.25), value: isHighlighted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHighlighted ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.25), value: isHighlighted)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    // MARK: - Index Picker (fixed width)

    @ViewBuilder
    private var indexPicker: some View {
        switch binding.input.type {
        case .button:
            Picker("", selection: $binding.input.index) {
                ForEach(0..<64, id: \.self) { i in
                    Text("Button \(i)").tag(i)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .axis:
            Picker("", selection: $binding.input.index) {
                ForEach(0..<16, id: \.self) { i in
                    Text("Axis #\(i)").tag(i)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .hat:
            Picker("", selection: $binding.input.index) {
                ForEach(0..<16, id: \.self) { i in
                    Text("Hat #\(i)").tag(i)
                }
            }
            .labelsHidden()
            .controlSize(.small)
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
            Picker("", selection: axisDirectionBinding) {
                ForEach(AxisDirection.allCases) { dir in
                    Text(dir.displayName).tag(dir)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .hat:
            Picker("", selection: hatDirectionBinding) {
                ForEach(HatDirection.allCases) { dir in
                    Text(dir.displayName).tag(dir)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    // MARK: - Output Value Controls

    @ViewBuilder
    private func outputValueControls(at index: Int) -> some View {
        let actionBinding = outputBinding(at: index)

        switch binding.outputs[index].type {
        case .key:
            KeyCodePicker(selectedCode: keyCodeBinding(at: index))

        case .mouseButton:
            Picker("", selection: mouseButtonBinding(at: index)) {
                ForEach(0..<32, id: \.self) { i in
                    Text(mouseButtonName(i)).tag(i)
                }
            }
            .labelsHidden()
            .frame(minWidth: 120)
            .controlSize(.small)

        case .mouseMotion, .mouseWheel:
            HStack(spacing: 8) {
                Picker("", selection: mouseAxisDirBinding(at: index)) {
                    Text("Up").tag("1 -")
                    Text("Right").tag("0 +")
                    Text("Down").tag("1 +")
                    Text("Left").tag("0 -")
                }
                .labelsHidden()
                .frame(width: 72)
                .controlSize(.small)

                Text("Speed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Slider(value: speedBinding(at: index), in: 1...50, step: 1)
                    .frame(minWidth: 80, idealWidth: 100)

                TextField("", value: speedIntBinding(at: index), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
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
                    .foregroundStyle(output.type == .key ? .orange : .purple)
                    .frame(width: 14)

                Picker("", selection: outputTypeBinding(at: index)) {
                    ForEach(OutputType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
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
                            .font(.system(size: 7))
                        Text(hasAdvancedOptions ? "Options *" : "Options")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(hasAdvancedOptions ? Color.blue : Color.gray.opacity(0.4))
                }
                .buttonStyle(.plain)
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
        (binding.macroSteps?.isEmpty == false)
    }

    @ViewBuilder
    private var advancedOptionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                if binding.input.type == .axis {
                    advancedAxisOptions
                }
                advancedModeOptions
                Spacer()
            }

            if showMacroEditor {
                macroEditorSection
            }
        }
        .padding(.leading, dragWidth + colGap)
    }

    @ViewBuilder
    private var advancedAxisOptions: some View {
        // Deadzone
        HStack(spacing: 4) {
            Text("Deadzone")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: deadzoneBinding, in: 0.01...0.9, step: 0.01)
                .frame(width: 70)
            let dzPct = String(format: "%.0f%%", (binding.deadzone ?? 0.25) * 100)
            Text(dzPct)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30)
        }

        // Invert
        Toggle(isOn: invertBinding) {
            Text("Invert")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)

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

        // Macro button
        Button {
            withAnimation { showMacroEditor.toggle() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                Text("Macro")
                    .font(.system(size: 9))
            }
            .foregroundStyle(binding.macroSteps?.isEmpty == false ? Color.orange : Color.gray.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Advanced Bindings

    private var deadzoneBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(binding.deadzone ?? 0.25) },
            set: { binding.deadzone = Float($0) }
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

    // MARK: - Macro Editor

    private var macroEditorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Macro Sequence")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    var steps = binding.macroSteps ?? []
                    steps.append(MacroStep(action: OutputAction(type: .key, keyCode: 4)))
                    binding.macroSteps = steps
                } label: {
                    Label("Add Step", systemImage: "plus.circle")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if let steps = binding.macroSteps, !steps.isEmpty {
                macroStepsList(steps)
            } else {
                Text("No steps. Add steps to create a macro sequence that fires on press.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Text("Macros override normal outputs. Each step fires in sequence with configurable delays.")
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

            Picker("", selection: macroStepTypeBinding(at: index)) {
                ForEach(OutputType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
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

            Spacer()
        }
    }

    // MARK: - Macro Bindings

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

    private func outputIcon(for action: OutputAction) -> String {
        switch action.type {
        case .key: return "keyboard"
        case .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep: return "computermouse"
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

    private func mouseButtonBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].mouseButtonIndex ?? 0 },
            set: { binding.outputs[index].mouseButtonIndex = $0 }
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

    private func speedIntBinding(at index: Int) -> SwiftUI.Binding<Int> {
        SwiftUI.Binding(
            get: { binding.outputs[index].speed ?? 6 },
            set: { binding.outputs[index].speed = max(1, min(50, $0)) }
        )
    }

    private func removeOutput(at index: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            binding.outputs.remove(at: index)
        }
    }
}
