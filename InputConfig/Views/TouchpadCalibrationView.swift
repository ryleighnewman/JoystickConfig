import SwiftUI

/// Touchpad Setup sheet. A top-level device picker chooses which surface
/// the user is configuring; both tabs (Calibration and Regions) adapt to
/// that pick.
///
/// **Calibration tab** is finger-driven on DualSense / DS4 (drag-to-fill
/// the grid; save min/max bounds), or shows an info banner on Mac Trackpad
/// (cursor coords are already absolute, no sweep required).
///
/// **Regions tab** stores zones in either `TouchpadService` (DualSense /
/// DS4) or `CursorRegionService` (Mac Trackpad). The per-region "Bind to"
/// popover writes a binding straight into the active preset, so the user
/// doesn't have to leave the sheet to wire a region to a key.
struct TouchpadCalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var presetStore: PresetStore
    @StateObject private var cursorRegions = CursorRegionService.shared

    enum Tab: String, CaseIterable, Identifiable {
        case calibration
        case regions
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .calibration: return "Calibration"
            case .regions:     return "Regions"
            }
        }
    }

    @State private var selectedTab: Tab = .calibration

    /// Which physical surface the sheet is operating on. Persisted in
    /// TouchpadService.currentActiveDevice so the picker reopens to the
    /// user's last pick.
    @State private var activeDevice: TouchpadDevice = TouchpadService.shared.currentActiveDevice()

    // MARK: - Shared state

    /// Live finger 0 / 1 position in normalized 0..1 coordinates, refreshed
    /// at 30 Hz by the polling timer.
    @State private var liveFinger0: CGPoint?
    @State private var liveFinger1: CGPoint?
    @State private var pollTimer: Timer?

    private let surfaceWidth: Int
    private let surfaceHeight: Int

    // MARK: - Calibration tab state

    private let gridColumns = 12
    private let gridRows = 7

    /// Sweep storage uses plain `@State` on the parent view, same
    /// shape v1.1 shipped with. The buffer / publishVersion /
    /// throttled-Canvas attempts kept either over-throttling (visible
    /// delay) or under-throttling (full-body re-eval storm during
    /// sweeps). v1.1's straightforward @State approach was smooth
    /// because v1.1's parent body was tiny; we match that by
    /// compacting the device picker into a single menu instead of
    /// four chips so this view's body re-eval cost is the same as
    /// v1.1's was.
    @State private var touched: [Bool]
    @State private var minX: Int = .max
    @State private var maxX: Int = .min
    @State private var minY: Int = .max
    @State private var maxY: Int = .min
    @State private var showSavedConfirmation: Bool = false
    @State private var showUnsavedCloseDialog: Bool = false
    @State private var savedCalibrationOnOpen: TouchpadCalibration = .uncalibrated

    /// Toast shown briefly after a Quick Zero hit.
    @State private var showQuickZeroToast: Bool = false
    /// Toast shown if the user pressed Quick Zero without a finger on the
    /// touchpad. We can't recenter without a current position to anchor to.
    @State private var showQuickZeroNeedsFinger: Bool = false

    // MARK: - Regions tab state

    /// Local copy of whichever region list the active device uses.
    /// Mutated by the UI, then pushed to TouchpadService or
    /// CursorRegionService depending on `activeDevice`.
    @State private var regions: [TouchpadRegion] = []
    @State private var selectedRegionID: UUID?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var drawingNewRegion = false
    @State private var renamingRegionID: UUID?
    @State private var renamingText: String = ""
    /// The region currently showing a "Bind to" popover. nil when no
    /// popover is open. Drives a popover anchored on the bind button in
    /// the region row.
    @State private var bindingPopoverRegionID: UUID?
    /// Confirmation toast after the "Apply default 1 to 16" action.
    @State private var showAppliedDefaultsToast: Bool = false

    init() {
        let (w, h) = TouchpadService.shared.nominalSurfaceSize
        self.surfaceWidth = w
        self.surfaceHeight = h
        _touched = State(initialValue: Array(repeating: false, count: 12 * 7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Touchpad Setup")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            devicePicker

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Setup section")

            switch selectedTab {
            case .calibration:
                calibrationTab
            case .regions:
                regionsTab
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { attemptClose() }
                    .buttonStyle(.solidSecondary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close touchpad setup")
            }
        }
        .padding(22)
        .frame(width: 760, height: 640)
        .onAppear {
            TouchpadService.shared.retain()
            startPolling()
            reloadRegionsForActiveDevice()
            loadSavedCalibration()
        }
        .onDisappear {
            stopPolling()
            TouchpadService.shared.release()
        }
        .onChange(of: activeDevice) { _, newDevice in
            TouchpadService.shared.setActiveDevice(newDevice)
            // Region storage differs per device, so swap lists when the
            // user flips the picker.
            reloadRegionsForActiveDevice()
            selectedRegionID = nil
            drawingNewRegion = false
            dragStart = nil
            dragCurrent = nil
        }
        .confirmationDialog(
            "You recorded a new calibration. Would you like to save it?",
            isPresented: $showUnsavedCloseDialog,
            titleVisibility: .visible
        ) {
            Button("Save Calibration") {
                saveCalibration()
                dismiss()
            }
            Button("Discard", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("Your recorded X range \(minX) to \(maxX), Y range \(minY) to \(maxY) hasn't been saved yet. Closing will discard it unless you save first.")
        }
    }

    // MARK: - Device picker

    /// Compact one-line device picker. The previous 4-chip row plus
    /// help text doubled the parent view body weight compared to v1.1,
    /// which is what made the calibration sheet feel laggy during
    /// finger sweeps (every cell-crossing re-evaluated all of the
    /// device picker chrome along with the grid). This single Menu is
    /// roughly equivalent body weight to the v1.1 tab picker alone.
    private var devicePicker: some View {
        HStack(spacing: 8) {
            // Menu wrapped in a rounded-rectangle chip so it looks like
            // an intentional control rather than a bare menu button.
            // `.menuStyle(.button)` + `.buttonStyle(.plain)` strips the
            // built-in chrome so the chip below is what the user sees,
            // and `.focusEffectDisabled()` kills the macOS default
            // focus ring (the thick blue rectangle that appeared on
            // keyboard focus / right after a click). Same pattern the
            // toolbar uses to suppress its focus rings.
            Menu {
                ForEach(TouchpadDevice.allCases) { device in
                    Button {
                        activeDevice = device
                    } label: {
                        Label { Text(device.displayName) } icon: { MenuIcon(name: device.iconName) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    IconView(name: activeDevice.iconName, glyphHeight: 13)
                        .font(.callout)
                    Text(activeDevice.displayName)
                        .font(.callout.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .focusEffectDisabled()
            .fixedSize()
            .accessibilityLabel("Which touchpad")
            .accessibilityHint("Choose between DualSense, DualShock 4, or Mac Trackpad")

            Text(activeDeviceShortHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// Short single-line caption for the compact picker. The full
    /// multi-line explanation that used to sit under the chip row
    /// added body weight every render; we trim to a single hint.
    private var activeDeviceShortHint: String {
        switch activeDevice {
        case .dualSense:   return "Per-finger touchpad over USB or Bluetooth."
        case .dualShock4:  return "Per-finger touchpad over USB or Bluetooth."
        case .macTrackpad: return "Uses cursor zones (no per-finger HID on Mac)."
        }
    }

    // MARK: - Close handling

    private func attemptClose() {
        if hasUnsavedRecording {
            showUnsavedCloseDialog = true
        } else {
            dismiss()
        }
    }

    private var hasUnsavedRecording: Bool {
        guard activeDevice.canFingerCalibrate else { return false }
        guard canSaveCalibration else { return false }
        let saved = TouchpadService.shared.currentCalibration()
        return minX != saved.minX || maxX != saved.maxX
            || minY != saved.minY || maxY != saved.maxY
    }

    // MARK: - Calibration tab

    @ViewBuilder
    private var calibrationTab: some View {
        if activeDevice.canFingerCalibrate {
            fingerCalibrationTab
        } else {
            macTrackpadCalibrationTab
        }
    }

    @ViewBuilder
    private var fingerCalibrationTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if savedCalibrationOnOpen.isUserCalibrated {
                savedCalibrationBanner
            }

            Text("Drag your finger across the entire touchpad until every cell is filled. InputConfig records the bounds and uses them so swipes feel uniform.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            calibrationPanel
                .aspectRatio(CGFloat(surfaceWidth) / CGFloat(surfaceHeight), contentMode: .fit)

            calibrationFooter
        }
    }

    /// Mac Trackpad branch of the Calibration tab. There is no calibration
    /// to do here, so the panel just explains what's going on and offers
    /// a shortcut to the Regions tab where the actual work happens.
    @ViewBuilder
    private var macTrackpadCalibrationTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.title2)
                    .iconTint(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No calibration needed")
                        .font(.subheadline.weight(.semibold))
                    Text("Cursor coordinates on the Mac Trackpad are already in absolute screen space. Switch to the Regions tab to draw screen rectangles. Each region triggers a binding while the mouse cursor is inside.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.4), lineWidth: 1))

            screenPreviewPanel

            HStack {
                Spacer()
                Button {
                    selectedTab = .regions
                } label: {
                    Label("Go to Regions", systemImage: "arrow.right")
                }
                .buttonStyle(.solidSecondary)
            }
        }
    }

    /// Live screen preview shown in Mac Trackpad calibration mode. Draws
    /// the primary screen rectangle scaled to fit, with a dot at the
    /// current normalized cursor position.
    private var screenPreviewPanel: some View {
        let aspect: CGFloat = {
            guard let frame = NSScreen.main?.frame, frame.height > 0 else { return 16.0 / 10.0 }
            return frame.width / frame.height
        }()
        return GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 10).stroke(Color.mint.opacity(0.6), lineWidth: 1.5)
                cursorPreviewDot(in: geo.size)
                Text("Primary display")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    @ViewBuilder
    private func cursorPreviewDot(in size: CGSize) -> some View {
        let p = cursorRegions.cursorNormalized
        Circle()
            .fill(Color.mint)
            .frame(width: 18, height: 18)
            .position(x: p.x * size.width, y: p.y * size.height)
            .shadow(color: .mint.opacity(0.6), radius: 6)
    }

    /// Bottom row of the finger-calibration tab: coverage stats + Quick
    /// Zero + Reset + Save buttons. Quick Zero is enabled for DualSense /
    /// DS4 only.
    @ViewBuilder
    private var calibrationFooter: some View {
        HStack(spacing: 20) {
            statBlock(label: "Coverage", value: "\(coveragePercent)%",
                      tint: coveragePercent >= minCoveragePercent ? .green : .secondary)
            statBlock(label: "X range",
                      value: minX <= maxX ? "\(minX) to \(maxX)" : "n/a",
                      tint: .secondary)
            statBlock(label: "Y range",
                      value: minY <= maxY ? "\(minY) to \(maxY)" : "n/a",
                      tint: .secondary)
            Spacer()

            if showQuickZeroToast {
                Label("Centered", systemImage: "scope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else if showQuickZeroNeedsFinger {
                Label("Touch the pad first", systemImage: "hand.point.up.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            } else if showSavedConfirmation {
                Label("Calibration saved", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Button {
                doQuickZero()
            } label: {
                Label("Quick Zero", systemImage: "scope")
            }
            .buttonStyle(.solidSecondaryCompact)
            .disabled(!activeDevice.canQuickZero)
            .help(activeDevice.canQuickZero
                  ? "Mark the current finger position as the new origin"
                  : "Mac Trackpad uses absolute screen coordinates, no zero to set")
            .accessibilityLabel("Quick zero the touchpad")
            .accessibilityHint("Marks the current finger position as the new origin")

            Button("Reset", role: .destructive) { resetCalibration() }
                .accessibilityLabel("Reset calibration")

            Button {
                saveCalibration()
            } label: {
                Label("Save Calibration", systemImage: "checkmark.seal.fill")
            }
            .buttonStyle(.solid)
            .disabled(!canSaveCalibration)
            .help(canSaveCalibration
                  ? "Save the calibrated bounds"
                  : "Drag your finger across the touchpad first to record an X / Y range")
            .accessibilityLabel("Save calibration")
        }
    }

    private let minCoveragePercent = 30

    private var savedCalibrationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .iconTint(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibration saved and active")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("X range \(savedCalibrationOnOpen.minX) to \(savedCalibrationOnOpen.maxX) , Y range \(savedCalibrationOnOpen.minY) to \(savedCalibrationOnOpen.maxY)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let when = savedCalibrationOnOpen.savedAt {
                    Text("Last saved \(when, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.5), lineWidth: 1))
    }

    /// v1.1's calibration panel verbatim: a ForEach over touched cells
    /// emitting Rectangle views, with the grid lines drawn as a Path
    /// stroke and the live finger dots overlaid on top. The Canvas /
    /// TimelineView / buffer experiments added either latency or
    /// rendering complexity that hurt smoothness; this shape was the
    /// one that shipped working in the v1.1 release, so we restore it.
    private var calibrationPanel: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25))
                let cellW = geo.size.width / CGFloat(gridColumns)
                let cellH = geo.size.height / CGFloat(gridRows)
                ForEach(0..<(gridColumns * gridRows), id: \.self) { idx in
                    if touched[idx] {
                        let col = idx % gridColumns
                        let row = idx / gridColumns
                        Rectangle()
                            .fill(Color.mint.opacity(0.45))
                            .frame(width: cellW, height: cellH)
                            .position(x: cellW * (CGFloat(col) + 0.5),
                                      y: cellH * (CGFloat(row) + 0.5))
                    }
                }
                Path { path in
                    for i in 1..<gridColumns {
                        let x = cellW * CGFloat(i)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    for i in 1..<gridRows {
                        let y = cellH * CGFloat(i)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.mint.opacity(0.18), lineWidth: 1)
                // Border stroked LAST so it sits cleanly on top of
                // the cell fills, hiding any cell edges that would
                // otherwise poke past the rounded corners.
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.mint.opacity(0.6), lineWidth: 1.5)
                fingerDots(in: geo.size)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Regions tab

    @ViewBuilder
    private var regionsTab: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(regionsHeadline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                regionsPanel
                    .aspectRatio(regionsAspect, contentMode: .fit)

                regionsToolbar
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            regionsList
                .frame(width: 260)
        }
    }

    private var regionsHeadline: String {
        if drawingNewRegion {
            return activeDevice == .macTrackpad
                ? "Click and drag on the screen preview to draw the new cursor region."
                : "Click and drag on the touchpad surface to draw the new region."
        }
        switch activeDevice {
        case .macTrackpad:
            return "Cursor zones on the Mac Trackpad. Draw rectangles on the screen preview, then bind each one to a key or button."
        case .dualSense, .dualShock4:
            return "Tap zones on the controller touchpad. Bindings of type Touchpad Region fire while a finger is inside."
        }
    }

    private var regionsAspect: CGFloat {
        if activeDevice == .macTrackpad {
            if let frame = NSScreen.main?.frame, frame.height > 0 {
                return frame.width / frame.height
            }
            return 16.0 / 10.0
        }
        return CGFloat(surfaceWidth) / CGFloat(surfaceHeight)
    }

    @ViewBuilder
    private var regionsToolbar: some View {
        HStack {
            Button {
                drawingNewRegion = true
                dragStart = nil
                dragCurrent = nil
            } label: {
                Label("Add Region", systemImage: "plus.rectangle")
            }
            .buttonStyle(.solidSecondaryCompact)
            .disabled(drawingNewRegion || regions.count >= 16)
            if drawingNewRegion {
                Button("Cancel") {
                    drawingNewRegion = false
                    dragStart = nil
                    dragCurrent = nil
                }
                .buttonStyle(.solidSecondaryCompact)
            }
            Button {
                applyDefault1to16()
            } label: {
                Label("Apply default 1 to 16", systemImage: "square.grid.4x3.fill")
            }
            .buttonStyle(.solidSecondaryCompact)
            .help("Replace regions with a 4 by 4 grid and bind each to keys 1 to 9, 0, F1 to F6 in the active preset")
            .disabled(presetStore.activePresetId == nil)
            if showAppliedDefaultsToast {
                Label("Default grid applied", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            Spacer()
            Text("\(regions.count) / 16 regions")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var regionsPanel: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 10).stroke(Color.mint.opacity(0.6), lineWidth: 1.5)

                ForEach(regions) { region in
                    regionShape(region: region, in: geo.size)
                }

                if drawingNewRegion, let start = dragStart, let current = dragCurrent {
                    let r = CGRect(
                        x: min(start.x, current.x),
                        y: min(start.y, current.y),
                        width: abs(current.x - start.x),
                        height: abs(current.y - start.y))
                    Rectangle()
                        .fill(Color.yellow.opacity(0.25))
                        .overlay(Rectangle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }

                if activeDevice == .macTrackpad {
                    cursorPreviewDot(in: geo.size)
                } else {
                    fingerDots(in: geo.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(size: geo.size), including: drawingNewRegion ? .gesture : .none)
        }
    }

    @ViewBuilder
    private func regionShape(region: TouchpadRegion, in size: CGSize) -> some View {
        let isPressed = isRegionPressed(region.id)
        let isSelected = region.id == selectedRegionID
        let rect = CGRect(
            x: region.minX * size.width,
            y: region.minY * size.height,
            width: (region.maxX - region.minX) * size.width,
            height: (region.maxY - region.minY) * size.height)
        let color = paletteColor(at: region.colorIndex)
        let fillOpacity: Double = isPressed ? 0.65 : (isSelected ? 0.45 : 0.25)
        let strokeWidth: CGFloat = isSelected ? 2 : 1

        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(fillOpacity))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: strokeWidth))
            .overlay(
                Text(region.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.85))
                    .clipShape(Capsule()),
                alignment: .topLeading
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture {
                if !drawingNewRegion {
                    selectedRegionID = region.id
                }
            }
    }

    private var regionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Defined Regions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if regions.isEmpty {
                Text("None yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(regions) { region in
                            regionRow(region)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func regionRow(_ region: TouchpadRegion) -> some View {
        let isSelected = region.id == selectedRegionID
        let color = paletteColor(at: region.colorIndex)
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            if renamingRegionID == region.id {
                TextField("Name", text: $renamingText, onCommit: {
                    commitRename(for: region.id)
                })
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(region.name)
                        .font(.body)
                        .lineLimit(1)
                    if let label = boundOutputLabel(for: region.id) {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Not bound")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
            }
            if isRegionPressed(region.id) {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            Button {
                bindingPopoverRegionID = region.id
            } label: {
                Image(systemName: "link")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bind this region")
            .disabled(presetStore.activePresetId == nil)
            .help(presetStore.activePresetId == nil
                  ? "Open or create a preset to bind this region"
                  : "Bind this region to a key")
            .popover(isPresented: Binding(
                get: { bindingPopoverRegionID == region.id },
                set: { isShown in if !isShown { bindingPopoverRegionID = nil } }
            ), arrowEdge: .leading) {
                bindPopover(for: region)
            }
            .accessibilityLabel("Bind region \(region.name)")
            Menu {
                Button("Rename") {
                    renamingRegionID = region.id
                    renamingText = region.name
                }
                Button("Delete", role: .destructive) {
                    deleteRegion(region.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRegionID = region.id
        }
    }

    // MARK: - Bind popover

    /// Compact key picker shown when the user taps the link icon next to
    /// a region. Selecting a key writes a binding into the active preset's
    /// first joystick slot and closes the popover.
    @ViewBuilder
    private func bindPopover(for region: TouchpadRegion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bind \(region.name) to…")
                .font(.subheadline.weight(.semibold))
            Text("Picks a key to fire while this region is active. The binding is added to the current preset.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(quickBindOptions, id: \.label) { option in
                        Button {
                            bindRegion(region.id, toKeyCode: option.keyCode, label: option.label)
                            bindingPopoverRegionID = nil
                        } label: {
                            HStack {
                                Text(option.label)
                                    .frame(minWidth: 38, alignment: .leading)
                                    .font(.body.monospaced())
                                Text(option.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 280, height: 240)
        }
        .padding(14)
    }

    private struct QuickBindOption {
        let label: String
        let description: String
        let keyCode: Int
    }

    /// The shortlist of common keys shown in the per-region bind popover.
    /// Number row + function row are the most useful for region work; the
    /// editor still has the full picker for anything more exotic.
    private var quickBindOptions: [QuickBindOption] {
        var opts: [QuickBindOption] = []
        for digit in 1...9 {
            opts.append(QuickBindOption(label: "\(digit)", description: "Number row", keyCode: 29 + digit))
        }
        opts.append(QuickBindOption(label: "0", description: "Number row", keyCode: 39))
        for fn in 1...12 {
            opts.append(QuickBindOption(label: "F\(fn)", description: "Function row", keyCode: 57 + fn))
        }
        opts.append(QuickBindOption(label: "Space", description: "Spacebar", keyCode: 44))
        opts.append(QuickBindOption(label: "Return", description: "Enter / Return", keyCode: 40))
        opts.append(QuickBindOption(label: "Tab", description: "Tab", keyCode: 43))
        opts.append(QuickBindOption(label: "Esc", description: "Escape", keyCode: 41))
        return opts
    }

    // MARK: - Region drawing

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard drawingNewRegion else { return }
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                guard drawingNewRegion, let start = dragStart else { return }
                let end = value.location
                let normMinX = max(0, min(1, Double(min(start.x, end.x) / size.width)))
                let normMaxX = max(0, min(1, Double(max(start.x, end.x) / size.width)))
                let normMinY = max(0, min(1, Double(min(start.y, end.y) / size.height)))
                let normMaxY = max(0, min(1, Double(max(start.y, end.y) / size.height)))
                if (normMaxX - normMinX) > 0.04 && (normMaxY - normMinY) > 0.04 {
                    addRegion(minX: normMinX, maxX: normMaxX, minY: normMinY, maxY: normMaxY)
                }
                drawingNewRegion = false
                dragStart = nil
                dragCurrent = nil
            }
    }

    private func addRegion(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let name = "Region \(regions.count + 1)"
        let colorIndex = regions.count % TouchpadRegion.colorPalette.count
        let region = TouchpadRegion(name: name, minX: minX, maxX: maxX,
                                     minY: minY, maxY: maxY, colorIndex: colorIndex)
        regions.append(region)
        selectedRegionID = region.id
        persistRegions()
    }

    private func deleteRegion(_ id: UUID) {
        regions.removeAll { $0.id == id }
        if selectedRegionID == id { selectedRegionID = nil }
        if activeDevice.usesCursorRegions {
            cursorRegions.deleteRegion(id)
        } else {
            TouchpadService.shared.saveRegions(regions)
        }
    }

    private func commitRename(for id: UUID) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            regions[index].name = trimmed
            persistRegions()
        }
        renamingRegionID = nil
        renamingText = ""
    }

    // MARK: - Shared bits

    /// Finger dot overlay driven by TimelineView, not by parent @State.
    ///
    /// The previous implementation read `liveFinger0` / `liveFinger1`
    /// @State written by the parent's 60 Hz pollOnce. Every finger
    /// move re-evaluated the *entire* TouchpadCalibrationView body
    /// (device picker, tab picker, helper text, stat blocks, buttons,
    /// the works) just to move one dot 8 pixels. The visualizer's
    /// TouchpadWidget doesn't have that problem because its trail uses
    /// a TimelineView whose updates don't go through parent @State.
    ///
    /// This subview adopts the same pattern: TimelineView ticks at
    /// 60 Hz from the display refresh, reads TouchpadService directly,
    /// and renders only the dots. The parent's @State is unaffected
    /// so the rest of the sheet stays static between ticks.
    @ViewBuilder
    private func fingerDots(in size: CGSize) -> some View {
        FingerDotsOverlay(size: size)
    }

    private func statBlock(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.body.monospacedDigit()).foregroundStyle(tint)
        }
    }

    private func paletteColor(at index: Int) -> Color {
        let safeIndex = max(0, min(TouchpadRegion.colorPalette.count - 1, index))
        switch TouchpadRegion.colorPalette[safeIndex] {
        case "mint":   return .mint
        case "cyan":   return .cyan
        case "pink":   return .pink
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "indigo": return .indigo
        case "green":  return .green
        default:       return .mint
        }
    }

    // MARK: - Device-aware region storage

    private func reloadRegionsForActiveDevice() {
        switch activeDevice {
        case .macTrackpad:
            regions = cursorRegions.allRegions()
        case .dualSense, .dualShock4:
            regions = TouchpadService.shared.allRegions()
        }
    }

    /// Push the current `regions` array to whichever service is the
    /// authoritative store for the active device.
    private func persistRegions() {
        switch activeDevice {
        case .macTrackpad:
            // CursorRegionService is upsert/delete style; rather than
            // diffing we replay the full list to keep it simple.
            // 1. Delete any region in the store that's no longer local.
            let localIDs = Set(regions.map { $0.id })
            for stored in cursorRegions.allRegions() where !localIDs.contains(stored.id) {
                cursorRegions.deleteRegion(stored.id)
            }
            // 2. Upsert the current locals (covers add + rename + resize).
            for region in regions {
                cursorRegions.upsert(region)
            }
        case .dualSense, .dualShock4:
            TouchpadService.shared.saveRegions(regions)
        }
    }

    /// Pressed-state lookup that routes to the right service.
    private func isRegionPressed(_ id: UUID) -> Bool {
        if activeDevice.usesCursorRegions {
            return cursorRegions.isRegionPressed(id)
        }
        return TouchpadService.shared.isRegionPressed(id)
    }

    /// Look up the binding that currently fires this region in the active
    /// preset and produce a short label like "1" or "F2". nil if no
    /// matching binding exists yet.
    private func boundOutputLabel(for regionID: UUID) -> String? {
        guard let activeID = presetStore.activePresetId,
              let preset = presetStore.presets.first(where: { $0.id == activeID }) else {
            return nil
        }
        let inputType: InputType = activeDevice.usesCursorRegions ? .cursorRegion : .touchpadRegion
        for joystick in preset.joysticks {
            for binding in joystick.bindings {
                guard binding.input.type == inputType else { continue }
                let bindingRegionID: UUID? = activeDevice.usesCursorRegions
                    ? binding.input.cursorRegionID
                    : binding.input.touchpadRegionID
                if bindingRegionID == regionID, let first = binding.outputs.first {
                    return outputLabel(for: first)
                }
            }
        }
        return nil
    }

    private func outputLabel(for output: OutputAction) -> String? {
        if output.type == .key, let code = output.keyCode,
           let entry = KeyCodeMap.allKeys.first(where: { $0.code == code }) {
            return "Bound: \(entry.name)"
        }
        return "Bound: \(output.type)"
    }

    // MARK: - Binding writes

    /// Add a `.touchpadRegion` (or `.cursorRegion`) binding for the given
    /// region to the active preset's first joystick. Replaces any
    /// existing binding pointing at the same region so the user always
    /// ends up with exactly one wire per region.
    private func bindRegion(_ regionID: UUID, toKeyCode keyCode: Int, label: String) {
        guard let activeID = presetStore.activePresetId,
              let idx = presetStore.presets.firstIndex(where: { $0.id == activeID }) else {
            return
        }
        var preset = presetStore.presets[idx]
        guard !preset.joysticks.isEmpty else { return }

        let usesCursor = activeDevice.usesCursorRegions
        let inputType: InputType = usesCursor ? .cursorRegion : .touchpadRegion
        let newInput: InputEvent = usesCursor
            ? .cursorRegion(regionID)
            : .touchpadRegion(regionID)
        let newOutput = OutputAction(type: .key, keyCode: keyCode)
        let newBinding = BindingModel(input: newInput, outputs: [newOutput])

        // Remove any prior binding pointing at this region so we don't
        // stack duplicate wires.
        for j in 0..<preset.joysticks.count {
            preset.joysticks[j].bindings.removeAll { b in
                guard b.input.type == inputType else { return false }
                let bID = usesCursor ? b.input.cursorRegionID : b.input.touchpadRegionID
                return bID == regionID
            }
        }
        preset.joysticks[0].bindings.append(newBinding)
        presetStore.presets[idx] = preset
        presetStore.savePreset(preset)
    }

    // MARK: - Default 1 to 16

    /// Replace the region list with a 4 by 4 grid and bind each cell to a
    /// number / function key in the active preset.
    private func applyDefault1to16() {
        guard let activeID = presetStore.activePresetId,
              let idx = presetStore.presets.firstIndex(where: { $0.id == activeID }) else {
            return
        }
        var preset = presetStore.presets[idx]
        guard !preset.joysticks.isEmpty else { return }

        let usesCursor = activeDevice.usesCursorRegions
        let inputType: InputType = usesCursor ? .cursorRegion : .touchpadRegion

        // Wipe prior region bindings of the right type so we replace
        // cleanly rather than stacking.
        for j in 0..<preset.joysticks.count {
            preset.joysticks[j].bindings.removeAll { $0.input.type == inputType }
        }

        // Generate a 4 by 4 grid (16 cells). Cell (col, row) maps to
        // normalized rectangle (col/4, row/4) to ((col+1)/4, (row+1)/4).
        let cellW = 1.0 / 4.0
        let cellH = 1.0 / 4.0
        let keyCodes: [Int] = (1...9).map { 29 + $0 } + [39] + (1...6).map { 57 + $0 }
        let keyLabels = (1...9).map { "\($0)" } + ["0"] + (1...6).map { "F\($0)" }

        var newRegions: [TouchpadRegion] = []
        for cell in 0..<16 {
            let col = cell % 4
            let row = cell / 4
            let region = TouchpadRegion(
                name: keyLabels[cell],
                minX: Double(col) * cellW,
                maxX: Double(col + 1) * cellW,
                minY: Double(row) * cellH,
                maxY: Double(row + 1) * cellH,
                colorIndex: cell % TouchpadRegion.colorPalette.count
            )
            newRegions.append(region)
            let binding = BindingModel(
                input: usesCursor ? .cursorRegion(region.id) : .touchpadRegion(region.id),
                outputs: [OutputAction(type: .key, keyCode: keyCodes[cell])]
            )
            preset.joysticks[0].bindings.append(binding)
        }

        regions = newRegions
        persistRegions()
        presetStore.presets[idx] = preset
        presetStore.savePreset(preset)

        withAnimation(.easeIn(duration: 0.2)) { showAppliedDefaultsToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) { showAppliedDefaultsToast = false }
        }
    }

    // MARK: - Calibration logic

    private var coveragePercent: Int {
        let total = touched.count
        guard total > 0 else { return 0 }
        return Int(Double(touched.filter { $0 }.count) / Double(total) * 100)
    }

    private var canSaveCalibration: Bool {
        guard activeDevice.canFingerCalibrate else { return false }
        return minX < maxX && minY < maxY
            && minX != .max && maxX != .min && minY != .max && maxY != .min
    }

    private func resetCalibration() {
        touched = Array(repeating: false, count: gridColumns * gridRows)
        minX = .max; maxX = .min; minY = .max; maxY = .min
        TouchpadService.shared.saveCalibration(.uncalibrated)
        savedCalibrationOnOpen = .uncalibrated
        showSavedConfirmation = false
    }

    private func loadSavedCalibration() {
        let saved = TouchpadService.shared.currentCalibration()
        savedCalibrationOnOpen = saved
        guard saved.isUserCalibrated else { return }
        minX = saved.minX
        maxX = saved.maxX
        minY = saved.minY
        maxY = saved.maxY
        if let cells = saved.gridCells, cells.count == gridColumns * gridRows {
            touched = cells
        }
    }

    private func saveCalibration() {
        guard canSaveCalibration else { return }
        let toSave = TouchpadCalibration(minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                                          savedAt: Date(), gridCells: touched)
        TouchpadService.shared.saveCalibration(toSave)
        savedCalibrationOnOpen = TouchpadService.shared.currentCalibration()
        withAnimation(.easeIn(duration: 0.15)) {
            showSavedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showSavedConfirmation = false
            }
        }
    }

    private func doQuickZero() {
        let ok = TouchpadService.shared.quickZero()
        if ok {
            withAnimation(.easeIn(duration: 0.15)) { showQuickZeroToast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.3)) { showQuickZeroToast = false }
            }
        } else {
            withAnimation(.easeIn(duration: 0.15)) { showQuickZeroNeedsFinger = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.3)) { showQuickZeroNeedsFinger = false }
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        // 60 Hz - matches typical display refresh and is the sweet spot
        // between smoothness and SwiftUI render cost. 120 Hz forced too
        // many @State invalidations per second and caused the sheet to
        // feel choppier than the underlying data was, because the
        // render pipeline couldn't keep up with the rate at which we
        // were dirtying the view.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            pollOnce()
        }
        if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce() {
        // After moving finger-dot rendering into `FingerDotsOverlay`
        // (which reads TouchpadService directly via TimelineView), the
        // only remaining job of this timer is to feed grid-cell
        // ingest. `liveFinger0` / `liveFinger1` @State writes are no
        // longer used by any view, so we don't bother updating them -
        // that removes the SwiftUI body re-evaluation that was firing
        // 60×/sec on every finger move and dominating the
        // calibration sheet's perceived lag.
        let svc = TouchpadService.shared
        if let p = svc.currentPosition(finger: 0) {
            ingest(x: p.x, y: p.y)
        }
        if let p = svc.currentPosition(finger: 1) {
            ingest(x: p.x, y: p.y)
        }
    }

    private func ingest(x: Int, y: Int) {
        guard selectedTab == .calibration, activeDevice.canFingerCalibrate else { return }
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
        let col = max(0, min(gridColumns - 1,
                             Int(Double(x) / Double(surfaceWidth) * Double(gridColumns))))
        let row = max(0, min(gridRows - 1,
                             Int(Double(y) / Double(surfaceHeight) * Double(gridRows))))
        touched[row * gridColumns + col] = true
    }
}

/// Self-refreshing finger position overlay. Reads `TouchpadService`
/// directly from inside a `TimelineView`, so updates don't have to
/// propagate through the parent `TouchpadCalibrationView`'s @State and
/// re-evaluate its whole body. This is the same architectural pattern
/// the live visualizer's `TouchpadWidget` uses for its trail canvas.
///
/// The dots stay in sync with finger motion at 60 Hz without forcing
/// the much heavier surrounding sheet body (device picker, tab picker,
/// banner, stat blocks, save / quick-zero / reset buttons) to redraw.
private struct FingerDotsOverlay: View {
    let size: CGSize

    /// Cached touchpad surface dimensions. Same value the parent reads
    /// via TouchpadService.nominalSurfaceSize; pulling it once at init
    /// instead of inside the timeline closure keeps the hot path
    /// allocation-free.
    private let surfaceWidth: CGFloat
    private let surfaceHeight: CGFloat

    init(size: CGSize) {
        self.size = size
        let (w, h) = TouchpadService.shared.nominalSurfaceSize
        self.surfaceWidth = CGFloat(w)
        self.surfaceHeight = CGFloat(h)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { _ in
            ZStack {
                if let p = TouchpadService.shared.currentPosition(finger: 0) {
                    Circle()
                        .fill(Color.mint)
                        .frame(width: 18, height: 18)
                        .position(x: CGFloat(p.x) / surfaceWidth * size.width,
                                  y: CGFloat(p.y) / surfaceHeight * size.height)
                        .shadow(color: .mint.opacity(0.6), radius: 6)
                }
                if let p = TouchpadService.shared.currentPosition(finger: 1) {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 14, height: 14)
                        .position(x: CGFloat(p.x) / surfaceWidth * size.width,
                                  y: CGFloat(p.y) / surfaceHeight * size.height)
                        .shadow(color: .cyan.opacity(0.5), radius: 5)
                }
            }
        }
        // The dots cover the whole panel so the TimelineView's frame
        // matches; otherwise it would size to the implicit Circle
        // bounding box and clip dots near the edges.
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
