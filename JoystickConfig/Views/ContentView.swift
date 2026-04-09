import SwiftUI
import GameController

struct ContentView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine

    @State private var selectedPresetId: UUID?
    @State private var editingPreset: Preset?
    @State private var newlyCreatedPresetId: UUID?
    @State private var showingImportSheet = false

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        .sheet(item: $editingPreset, onDismiss: {
            // If the user cancelled a newly created preset, delete it
            if let newId = newlyCreatedPresetId {
                presetStore.deletePreset(presetStore.presets.first(where: { $0.id == newId })!)
                if selectedPresetId == newId { selectedPresetId = nil }
                newlyCreatedPresetId = nil
            }
        }) { preset in
            PresetEditorView(preset: preset) { updated in
                newlyCreatedPresetId = nil // Saved successfully, don't delete
                presetStore.savePreset(updated)
                editingPreset = nil
            }
            .environmentObject(controllerService)
            .environmentObject(mappingEngine)
            .frame(minWidth: 1050, idealWidth: 1300, minHeight: 700, idealHeight: 800)
        }
        .onAppear {
            presetStore.reseedExamplePresets()
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(spacing: 0) {
            controllerStatusBar

            List(selection: $selectedPresetId) {
                ForEach(presetStore.presets) { preset in
                    PresetRowView(
                        preset: preset,
                        onActivate: { togglePreset(preset) },
                        onEdit: { editingPreset = preset },
                        onDuplicate: { _ = presetStore.duplicatePreset(preset) },
                        onExport: { exportPreset(preset) },
                        onShowInFinder: { showPresetInFinder(preset) },
                        onShare: { sharePreset(preset) },
                        onImport: { showingImportSheet = true },
                        onDelete: { presetStore.deletePreset(preset) },
                        onConvert: { source, dest in
                            _ = presetStore.convertPreset(preset, from: source, to: dest)
                        }
                    )
                    .tag(preset.id)
                }
                .onMove { source, destination in
                    presetStore.movePresets(from: source, to: destination)
                }
            }
            .listStyle(.sidebar)

            bottomToolbar
        }
        .navigationTitle("Presets")
        .frame(minWidth: 280)
    }

    private static let controllerColors: [Color] = [.green, .purple, .red, .orange, .cyan, .pink, .yellow, .mint]

    private var controllerStatusBar: some View {
        VStack(spacing: 0) {
            if controllerService.connectedControllers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller")
                        .foregroundStyle(.secondary)
                    Text("No controllers connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                ForEach(Array(controllerService.connectedControllers.enumerated()), id: \.offset) { index, controller in
                    ControllerChipView(
                        controller: controller,
                        index: index,
                        color: Self.controllerColors[index % Self.controllerColors.count],
                        info: controllerService.controllerDetails[index],
                        onSetLight: { r, g, b in
                            controllerService.setControllerLight(at: index, red: r, green: g, blue: b)
                        },
                        onRefresh: {
                            controllerService.refreshControllers()
                        }
                    )
                }
            }

            if mappingEngine.isRunning {
                HStack(spacing: 6) {
                    Spacer()
                    Menu {
                        Button("Deactivate") {
                            if let active = presetStore.presets.first(where: { $0.isActive }) {
                                togglePreset(active)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("Active")
                                .font(.caption2)
                                .foregroundStyle(Color.green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.1))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
        .background(.bar)
    }

    private var bottomToolbar: some View {
        HStack(spacing: 10) {
            Button {
                let preset = presetStore.createPreset()
                selectedPresetId = preset.id
                newlyCreatedPresetId = preset.id
                editingPreset = preset
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)

            Spacer()

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://buymeacoffee.com/ryleighnewman")!) {
                    Text("Donate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .underline(color: .secondary.opacity(0.5))
                }

                Link(destination: URL(string: "https://github.com/ryleighnewman/JoystickConfig")!) {
                    Text("GitHub")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .underline(color: .secondary.opacity(0.5))
                }
            }

            Spacer()

            Button {
                showingImportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .fileImporter(
            isPresented: $showingImportSheet,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    _ = presetStore.importLegacyPreset(from: url)
                }
            }
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            if let presetId = selectedPresetId,
               let preset = presetStore.presets.first(where: { $0.id == presetId }) {
                PresetDetailView(
                    preset: presetBinding(for: preset),
                    onEdit: { editingPreset = preset },
                    onToggle: { togglePreset(preset) }
                )
                .environmentObject(mappingEngine)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 64))
                        .foregroundStyle(.tertiary)
                    Text("Select a preset or create a new one")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Button("Create New Preset") {
                        let preset = presetStore.createPreset()
                        selectedPresetId = preset.id
                        editingPreset = preset
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Log always visible at bottom
            Divider()
                .padding(.horizontal)
            DebugLogView()
                .environmentObject(mappingEngine)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    private func presetBinding(for preset: Preset) -> SwiftUI.Binding<Preset> {
        SwiftUI.Binding(
            get: { presetStore.presets.first(where: { $0.id == preset.id }) ?? preset },
            set: { newValue in
                presetStore.savePreset(newValue)
            }
        )
    }

    // MARK: - Actions

    private func togglePreset(_ preset: Preset) {
        if preset.isActive {
            mappingEngine.stop()
            presetStore.deactivateAll()
        } else {
            if preset.joysticks.isEmpty { return }
            mappingEngine.stop()
            presetStore.activatePreset(preset)
            mappingEngine.start(with: preset)
        }
    }

    private func exportPreset(_ preset: Preset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name).json"
        if panel.runModal() == .OK, let url = panel.url {
            presetStore.exportPresetToFile(preset, to: url)
        }
    }

    private func showPresetInFinder(_ preset: Preset) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let presetsDir = appSupport.appendingPathComponent("JoystickConfig/presets")
        let filePath = presetsDir.appendingPathComponent(preset.filename).path
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
    }

    private func sharePreset(_ preset: Preset) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let presetsDir = appSupport.appendingPathComponent("JoystickConfig/presets")
        let fileURL = presetsDir.appendingPathComponent(preset.filename)

        let picker = NSSharingServicePicker(items: [fileURL])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            let frame = contentView.bounds
            let rect = NSRect(x: frame.midX, y: frame.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }
}

// MARK: - Controller Chip View

struct ControllerChipView: View {
    let controller: GCController
    let index: Int
    let color: Color
    let info: ControllerInfo?
    let onSetLight: (Float, Float, Float) -> Void
    let onRefresh: () -> Void

    @State private var showPopover = false

    // macOS System Settings default colors + extras
    private static let lightPresets: [(name: String, r: Float, g: Float, b: Float)] = [
        ("Orange", 1.0, 0.6, 0.0),
        ("Blue", 0.0, 0.4, 1.0),
        ("Red", 1.0, 0.2, 0.2),
        ("Purple", 0.6, 0.2, 0.9),
        ("Green", 0.2, 0.8, 0.2),
        ("Yellow", 1.0, 0.9, 0.0),
        ("Cyan", 0.0, 0.8, 0.8),
        ("Pink", 1.0, 0.3, 0.5),
        ("White", 1.0, 1.0, 1.0),
        ("Off", 0.0, 0.0, 0.0),
    ]

    @State private var uptimeTimer: Timer?
    @State private var uptimeText: String = ""

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Controller icon
            Image(systemName: "gamecontroller.fill")
                .font(.caption)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(controller.vendorName ?? "Controller \(index)")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let info = info {
                    Text(shortDescription(info))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Battery indicator
            if let info = info, info.hasBattery, let level = info.batteryLevel {
                batteryView(level: level, state: info.batteryState)
            }

            // Light indicator
            if info?.hasLight == true {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow.opacity(0.7))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? color.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            showPopover.toggle()
        }
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            controllerPopover
        }
    }

    private func shortDescription(_ info: ControllerInfo) -> String {
        var parts: [String] = []
        parts.append(info.productCategory)
        parts.append("\(info.buttonCount) btns")
        parts.append("\(info.axisCount) axes")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func batteryView(level: Float, state: String?) -> some View {
        HStack(spacing: 2) {
            let pct = Int(level * 100)
            let icon: String = {
                if state == "Charging" { return "battery.100percent.bolt" }
                if pct >= 75 { return "battery.100percent" }
                if pct >= 50 { return "battery.75percent" }
                if pct >= 25 { return "battery.50percent" }
                return "battery.25percent"
            }()
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(pct <= 20 ? .red : .secondary)
            Text("\(pct)%")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Popover

    private var controllerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.vendorName ?? "Controller \(index)")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("Slot \(index)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !uptimeText.isEmpty {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(uptimeText)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
            }

            Divider()

            // Details
            if let info = info {
                detailGrid(info)
            }

            // Light color picker
            if info?.hasLight == true {
                Divider()
                lightColorSection
            }

            // Available buttons
            if let info = info, !info.physicalButtonNames.isEmpty {
                Divider()
                DisclosureGroup {
                    Text(info.physicalButtonNames.joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Raw Buttons (\(info.physicalButtonNames.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
                .focusable(false)
                .focusEffectDisabled()
            }

            Divider()

            Button {
                onRefresh()
                showPopover = false
            } label: {
                Label("Refresh Controllers", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { startUptimeTimer() }
        .onDisappear { uptimeTimer?.invalidate(); uptimeTimer = nil }
    }

    private func startUptimeTimer() {
        updateUptime()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in updateUptime() }
        }
    }

    private func updateUptime() {
        guard let info = info else { uptimeText = ""; return }
        let elapsed = Int(Date().timeIntervalSince(info.connectedAt))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        if h > 0 {
            uptimeText = String(format: "%d:%02d:%02d connected", h, m, s)
        } else {
            uptimeText = String(format: "%d:%02d connected", m, s)
        }
    }

    @ViewBuilder
    private func detailGrid(_ info: ControllerInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            detailRow("Type", info.productCategory)
            detailRow("Gamepad", info.hasExtendedGamepad ? "Extended" : "Basic")
            detailRow("Buttons", "\(info.buttonCount)")
            detailRow("Axes", "\(info.axisCount)")
            if info.supportsMotion {
                detailRow("Motion", "Gyro + Accelerometer")
            }
            if info.hasBattery {
                let level = info.batteryLevel.map { "\(Int($0 * 100))%" } ?? "N/A"
                let state = info.batteryState ?? "Unknown"
                detailRow("Battery", "\(level) (\(state))")
            }
            detailRow("Light Bar", info.hasLight ? "Supported" : "None")
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
        }
    }

    private var lightColorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Light Bar Color")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 8) {
                ForEach(Self.lightPresets, id: \.name) { preset in
                    let swatchColor = preset.name == "Off" ? Color.gray.opacity(0.3) :
                        Color(red: Double(preset.r), green: Double(preset.g), blue: Double(preset.b))
                    LightSwatchButton(
                        name: preset.name,
                        color: swatchColor,
                        action: { onSetLight(preset.r, preset.g, preset.b) }
                    )
                }
            }
        }
    }
}

// MARK: - Light Swatch Button

private struct LightSwatchButton: View {
    let name: String
    let color: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Circle()
                    .fill(color)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(isHovering ? 0.4 : 0.12), lineWidth: isHovering ? 1.5 : 0.5)
                    )
                    .frame(width: 24, height: 24)
                    .shadow(color: color.opacity(isHovering ? 0.6 : 0.3), radius: isHovering ? 4 : 2)
                    .scaleEffect(isHovering ? 1.15 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: isHovering)
                Text(name)
                    .font(.system(size: 8))
                    .foregroundStyle(isHovering ? .secondary : .tertiary)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Preset Row View

struct PresetRowView: View {
    let preset: Preset
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onShowInFinder: () -> Void
    let onShare: () -> Void
    let onImport: () -> Void
    let onDelete: () -> Void
    let onConvert: (ControllerType, ControllerType) -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Circular activation indicator with glow
            ZStack {
                if preset.isActive {
                    Circle()
                        .fill(Color.green.opacity(0.25))
                        .frame(width: 24, height: 24)
                        .blur(radius: 4)

                    Circle()
                        .fill(Color.green)
                        .frame(width: 14, height: 14)
                        .shadow(color: Color.green.opacity(0.6), radius: 6, x: 0, y: 0)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.body)
                    .lineLimit(1)

                Text(preset.tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Options menu
            Menu {
                Button(preset.isActive ? "Deactivate" : "Activate") {
                    onActivate()
                }

                Button("Edit") {
                    onEdit()
                }

                Button("Duplicate") {
                    onDuplicate()
                }

                Divider()

                Menu("Convert To...") {
                    ForEach(ControllerType.allCases) { sourceType in
                        Menu("From \(sourceType.rawValue)") {
                            ForEach(ControllerType.allCases.filter { $0 != sourceType }) { destType in
                                Button("To \(destType.rawValue)") {
                                    onConvert(sourceType, destType)
                                }
                            }
                        }
                    }
                }

                Button("Export...") {
                    onExport()
                }

                Button("Import Preset File...") {
                    onImport()
                }

                Divider()

                Button("Show in Finder") {
                    onShowInFinder()
                }

                Button("Share...") {
                    onShare()
                }

                Divider()

                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundColor(Color.gray.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(preset.isActive ? "Deactivate" : "Activate") {
                onActivate()
            }

            Button("Edit") {
                onEdit()
            }

            Button("Duplicate") {
                onDuplicate()
            }

            Divider()

            Menu("Convert To...") {
                ForEach(ControllerType.allCases) { sourceType in
                    Menu("From \(sourceType.rawValue)") {
                        ForEach(ControllerType.allCases.filter { $0 != sourceType }) { destType in
                            Button("To \(destType.rawValue)") {
                                onConvert(sourceType, destType)
                            }
                        }
                    }
                }
            }

            Button("Export...") { onExport() }
            Button("Import Preset File...") { onImport() }

            Divider()

            Button("Show in Finder") { onShowInFinder() }
            Button("Share...") { onShare() }

            Divider()

            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Preset Detail View

struct PresetDetailView: View {
    @SwiftUI.Binding var preset: Preset
    let onEdit: () -> Void
    let onToggle: () -> Void

    @EnvironmentObject var mappingEngine: MappingEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Preset Name", text: $preset.name)
                                .font(.title2)
                                .fontWeight(.regular)
                                .textFieldStyle(.plain)

                            TextField("Tag / Description", text: $preset.tag)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textFieldStyle(.plain)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button(action: onToggle) {
                                Label(
                                    preset.isActive ? "Deactivate" : "Activate",
                                    systemImage: preset.isActive ? "stop.fill" : "play.fill"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(preset.isActive ? .red : .green)
                            .controlSize(.regular)

                            Button("Edit Preset", action: onEdit)
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Divider()
                        .padding(.horizontal)

                    // Joystick summary cards
                    ForEach(Array(preset.joysticks.enumerated()), id: \.element.id) { index, joystick in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Joystick #\(index)")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(joystick.bindings.count) bindings")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            if !joystick.tag.isEmpty && joystick.tag != "<write comments here>" {
                                Text(joystick.tag)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                        )
                        .padding(.horizontal)
                    }

                    if preset.joysticks.isEmpty {
                        ContentUnavailableView {
                            Label("No Joystick Mappings", systemImage: "gamecontroller")
                        } description: {
                            Text("Edit this preset to add joystick mappings.")
                        }
                    }
                }
                .padding(.vertical)
            }

        }
        .navigationTitle(preset.name)
    }
}
