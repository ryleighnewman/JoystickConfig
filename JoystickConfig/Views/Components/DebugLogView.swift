import SwiftUI

struct DebugLogView: View {
    @EnvironmentObject var mappingEngine: MappingEngine

    @State private var isExpanded = true
    @State private var filterText = ""
    @State private var showPressOnly = false
    @State private var autoScroll = true
    @State private var logHeight: CGFloat = 180

    private static let controllerColors: [Color] = [.green, .purple, .red, .orange, .cyan, .pink, .yellow, .mint]

    private var filteredLog: [(text: String, joystickIndex: Int?)] {
        var lines = mappingEngine.debugLog
        if showPressOnly {
            lines = lines.filter { $0.text.contains("PRESS") || $0.text.contains("RELEASE") }
        }
        if !filterText.isEmpty {
            lines = lines.filter { $0.text.localizedCaseInsensitiveContains(filterText) }
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Unified toolbar
            toolbar

            if isExpanded {
                // Log content
                logContent

                // Status bar
                statusBar
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 0.5)
        )
        .padding(.horizontal)
    }

    // MARK: - Unified Toolbar

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Collapse toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)

                Text("Log")
                    .font(.subheadline)

                if mappingEngine.isRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Live")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                }

                if isExpanded {
                    // Separator
                    Divider()
                        .frame(height: 14)

                    // Search field
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        TextField("Filter...", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                        if !filterText.isEmpty {
                            Button {
                                filterText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    )
                    .frame(maxWidth: 160)

                    Toggle(isOn: $showPressOnly) {
                        Text("Events only")
                            .font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                    Toggle(isOn: $autoScroll) {
                        Text("Auto-scroll")
                            .font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }

                Spacer()

                if !mappingEngine.activeInputs.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                        Text("\(mappingEngine.activeInputs.count)")
                            .font(.caption)
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                }

                // Copy
                Button {
                    let text = mappingEngine.debugLog.map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy log to clipboard")

                // Clear
                Button {
                    mappingEngine.debugLog.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear log")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if isExpanded {
                // Resize handle integrated into toolbar bottom edge
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 3)
                    .frame(maxWidth: 40)
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle().inset(by: -6))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newHeight = logHeight - value.translation.height
                                logHeight = min(max(newHeight, 80), 500)
                            }
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }
        }
    }

    // MARK: - Log Content

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if filteredLog.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(filteredLog.enumerated()), id: \.offset) { index, entry in
                            logLineView(entry.text, joystickIndex: entry.joystickIndex)
                                .id(index)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(height: logHeight)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.85))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
            .padding(.horizontal, 8)
            .onChange(of: mappingEngine.debugLog.count) { _, _ in
                if autoScroll, let lastIndex = filteredLog.indices.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.justify.left")
                .font(.title2)
                .foregroundStyle(.secondary.opacity(0.5))
            Text(mappingEngine.isRunning ? "No matching log entries" : "Activate a preset to start logging")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func logLineView(_ line: String, joystickIndex: Int?) -> some View {
        let color = logLineColor(line, joystickIndex: joystickIndex)
        return HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .padding(.top, 5)

            Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    private func logLineColor(_ line: String, joystickIndex: Int?) -> Color {
        if let idx = joystickIndex, (line.contains("PRESS") || line.contains("RELEASE") || line.contains("Raw state")) {
            return Self.controllerColors[idx % Self.controllerColors.count]
        }
        if line.contains("PRESS") { return .green }
        if line.contains("RELEASE") { return .orange }
        if line.contains("Engine started") { return .cyan }
        if line.contains("Engine stopped") { return .red }
        if line.contains("No controller") { return .red.opacity(0.7) }
        if line.contains("Raw state") { return .yellow.opacity(0.7) }
        if line.contains("Controller") || line.contains("Joystick") { return .blue.opacity(0.8) }
        return .white.opacity(0.55)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(filteredLog.count) entries")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            if showPressOnly || !filterText.isEmpty {
                Text("(\(mappingEngine.debugLog.count) total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if mappingEngine.isRunning {
                Text("120 Hz polling")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
