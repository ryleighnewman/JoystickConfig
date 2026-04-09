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

    @EnvironmentObject var mappingEngine: MappingEngine
    @State private var preSortSnapshot: [BindingModel]?

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if joystick.isExpanded {
                VStack(spacing: 2) {
                    ForEach(Array(joystick.bindings.enumerated()), id: \.element.id) { index, binding in
                        BindingRowView(
                            binding: bindingAt(index),
                            onScan: { onScanInput(index) },
                            onRemove: { onRemoveBinding(index) },
                            onDuplicate: { onDuplicateBinding(index) },
                            isHighlighted: mappingEngine.activeInputs.contains(binding.input.serialized)
                        )
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

                Button(action: onAddBinding) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.green)
                        Text("Add a new bind")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.green.opacity(0.03))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
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
                    Text("Joystick #\(joystickIndex)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(":")
                        .foregroundStyle(.tertiary)
                    Text(controllerName)
                        .font(.caption)
                        .foregroundStyle(controllerName.contains("No controller") ? .red.opacity(0.6) : .primary)
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

                Button(action: onDuplicate) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Clone this joystick group")

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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func bindingAt(_ index: Int) -> SwiftUI.Binding<BindingModel> {
        SwiftUI.Binding(
            get: { joystick.bindings[index] },
            set: { joystick.bindings[index] = $0 }
        )
    }
}
