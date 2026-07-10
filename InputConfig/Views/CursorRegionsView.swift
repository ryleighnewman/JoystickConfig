import SwiftUI
import AppKit

/// Lets the user define rectangular regions on the macOS display that
/// `.cursorRegion` bindings can target. Mirrors the layout and
/// interaction model of `TouchpadCalibrationView`'s region editor so
/// the two systems feel like the same thing applied to different
/// input surfaces:
///
///   - Explicit Add Region drawing mode (drag only consumed while in
///     drawing mode; no accidental sliver regions from stray clicks).
///   - Motionless canvas. Cursor position is shown as a small text
///     readout below the canvas instead of a live indicator that
///     constantly redraws the plane.
///   - Side-by-side layout: canvas on the left, region list on the
///     right with rename/delete in an ellipsis menu.
///   - Region count cap (16 to match touchpad).
struct CursorRegionsView: View {
    @ObservedObject private var svc = CursorRegionService.shared
    @ObservedObject private var externalInput = ExternalInputDeviceService.shared

    /// Drives the live cursor dot while this view is visible, since the
    /// service's continuous tracking only runs for an active preset. Stored
    /// once so re-renders do not recreate the subscription.
    private let cursorPollTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// Name of the display the cursor is currently on. Regions are
    /// normalized per screen, so this is the distinction the map needs on
    /// multi-display setups.
    @State private var currentScreenName: String = NSScreen.main?.localizedName ?? "Display"
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var selectedRegionID: UUID?

    @State private var drawingNewRegion = false
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    @State private var renamingRegionID: UUID?
    @State private var renamingText: String = ""

    private static let maxRegions = 16

    /// Live region list read from the @MainActor service. Sourcing
    /// directly from the @Published `regions` array (rather than
    /// duplicating into a local @State) keeps actor isolation clean
    /// and lets the UI react to external changes (e.g. binding row
    /// scanner adding a region) without a separate refresh.
    private var regions: [TouchpadRegion] { svc.regions }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            mainContent
            footer
        }
        .padding(20)
        .frame(width: 760, height: 560)
        // Drive the live cursor dot. CursorRegionService only samples the
        // pointer while something is tracking (permission-free
        // NSEvent.mouseLocation poll), so start it while this editor is
        // open and stop it on close.
        .onAppear { CursorRegionService.shared.beginTracking() }
        .onDisappear { CursorRegionService.shared.endTracking() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cursor Regions")
                .font(.title2.weight(.semibold))
            Text("Draw rectangles on screen. A binding fires while the cursor is inside one. Regions scale with your display.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Main layout

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(drawingNewRegion
                     ? "Click and drag on the screen preview to draw the new region."
                     : "Click Add Region, then drag on the screen preview to create one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                regionsPanel
                    .aspectRatio(canvasAspectRatio, contentMode: .fit)

                HStack {
                    Button {
                        drawingNewRegion = true
                        dragStart = nil
                        dragCurrent = nil
                    } label: {
                        Label("Add Region", systemImage: "plus.rectangle")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(drawingNewRegion || regions.count >= Self.maxRegions)

                    if drawingNewRegion {
                        Button("Cancel") {
                            drawingNewRegion = false
                            dragStart = nil
                            dragCurrent = nil
                        }
                        .buttonStyle(.solidSecondaryCompact)
                    }

                    Spacer()

                    Text(cursorReadout)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)

                    Text("\(regions.count) / \(Self.maxRegions) regions")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            regionsList
                .frame(width: 240)
        }
    }

    private var footer: some View {
        HStack {
            Text("Tip: bind to a region from the binding editor by setting input type to Cursor Region.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.solid)
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Canvas

    private var regionsPanel: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 10).stroke(Color.mint.opacity(0.6), lineWidth: 1.5)

                ForEach(regions) { region in
                    let isPressed = svc.isRegionPressed(region.id)
                    let isSelected = region.id == selectedRegionID
                    let rect = CGRect(
                        x: region.minX * geo.size.width,
                        y: region.minY * geo.size.height,
                        width: (region.maxX - region.minX) * geo.size.width,
                        height: (region.maxY - region.minY) * geo.size.height)
                    let color = paletteColor(at: region.colorIndex)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(isPressed ? 0.65 : (isSelected ? 0.45 : 0.25)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(color, lineWidth: isSelected ? 2 : 1)
                        )
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Region \(region.name)")
                        .accessibilityValue(canvasRegionValue(region, isPressed: isPressed))
                        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                }

                // Live cursor dot: shows where the pointer is RIGHT NOW in
                // the same normalized space the regions hit-test against,
                // so placing and sizing regions stops being guesswork.
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.mint, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .shadow(radius: 1)
                    .position(x: svc.cursorNormalized.x * geo.size.width,
                              y: svc.cursorNormalized.y * geo.size.height)
                    .allowsHitTesting(false)
                    .onReceive(cursorPollTimer) { _ in
                        svc.pollCursorOnce()
                        ExternalInputDeviceService.shared.ensurePressureMetricsMonitor()
                        let loc = NSEvent.mouseLocation
                        currentScreenName = NSScreen.screens.first(where: { $0.frame.contains(loc) })?.localizedName
                            ?? NSScreen.main?.localizedName ?? "Display"
                    }

                // Which display the map and dot currently represent.
                Text(currentScreenName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.4)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
                    .allowsHitTesting(false)

                // Live Force Touch pressure while pressing the Mac trackpad
                // over this window: the gauge fills with force, and "Deep"
                // marks a stage-2 Force Click. Bindable as Pressure and
                // Deep Press inputs on the Mouse input type.
                HStack(spacing: 5) {
                    Image(systemName: "hand.tap.fill")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    ProgressView(value: Double(min(max(externalInput.trackpadPressure, 0), 1)))
                        .frame(width: 64)
                    Text(externalInput.trackpadPressureStage >= 2
                         ? "Deep"
                         : String(format: "%.0f%%", externalInput.trackpadPressure * 100))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 34, alignment: .leading)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.4)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Trackpad pressure")
                .accessibilityValue(externalInput.trackpadPressureStage >= 2
                                    ? "Deep press"
                                    : "\(Int(externalInput.trackpadPressure * 100)) percent")

                if drawingNewRegion, let start = dragStart, let current = dragCurrent {
                    let r = CGRect(
                        x: min(start.x, current.x),
                        y: min(start.y, current.y),
                        width: abs(current.x - start.x),
                        height: abs(current.y - start.y))
                    Rectangle()
                        .fill(Color.yellow.opacity(0.25))
                        .overlay(Rectangle().stroke(Color.yellow,
                                                    style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(size: geo.size),
                     including: drawingNewRegion ? .gesture : .none)
        }
    }

    // MARK: - Region list

    private var regionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Defined Regions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
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
        let isPressed = svc.isRegionPressed(region.id)
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            if renamingRegionID == region.id {
                TextField("Name", text: $renamingText, onCommit: {
                    commitRename(for: region.id)
                })
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Rename region")
                .onExitCommand { cancelRename() }
            } else {
                Text(region.name)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
            }
            if isPressed {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
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
            .accessibilityLabel("Region options for \(region.name)")
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
        .accessibilityValue(isPressed ? "Active" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Drawing

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
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
                // Reject accidentally tiny regions.
                if (normMaxX - normMinX) > 0.04 && (normMaxY - normMinY) > 0.04 {
                    addRegion(minX: normMinX, maxX: normMaxX,
                              minY: normMinY, maxY: normMaxY)
                }
                drawingNewRegion = false
                dragStart = nil
                dragCurrent = nil
            }
    }

    private func addRegion(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let count = regions.count
        let name = "Region \(count + 1)"
        let colorIndex = count % TouchpadRegion.colorPalette.count
        let region = TouchpadRegion(name: name, minX: minX, maxX: maxX,
                                     minY: minY, maxY: maxY, colorIndex: colorIndex)
        svc.upsert(region)
        selectedRegionID = region.id
    }

    private func deleteRegion(_ id: UUID) {
        if selectedRegionID == id { selectedRegionID = nil }
        svc.deleteRegion(id)
    }

    private func commitRename(for id: UUID) {
        let trimmed = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, var region = svc.region(with: id) {
            region.name = trimmed
            svc.upsert(region)
        }
        renamingRegionID = nil
        renamingText = ""
    }

    /// Discards an in-progress rename without committing. Wired to
    /// Escape via `.onExitCommand` on the rename text field.
    private func cancelRename() {
        renamingRegionID = nil
        renamingText = ""
    }

    /// Spoken value for a canvas region: its normalized position and
    /// size plus whether it is currently pressed, so VoiceOver conveys
    /// the same information sighted users read off the drawn rectangle.
    private func canvasRegionValue(_ region: TouchpadRegion, isPressed: Bool) -> String {
        let x = Int(region.minX * 100)
        let y = Int(region.minY * 100)
        let w = Int((region.maxX - region.minX) * 100)
        let h = Int((region.maxY - region.minY) * 100)
        var value = "Positioned at \(x) percent across, \(y) percent down, \(w) by \(h) percent of the display"
        if isPressed {
            value += ", active"
        }
        return value
    }

    // MARK: - Helpers

    /// Primary screen aspect ratio. Used so the preview rectangle
    /// reflects actual screen proportions instead of guessing.
    private var canvasAspectRatio: CGFloat {
        guard let screen = NSScreen.main, screen.frame.height > 0 else { return 16.0 / 10.0 }
        return screen.frame.width / screen.frame.height
    }

    /// Compact text readout of the live cursor position. Lives below
    /// the canvas (not on it) so the canvas itself stays motionless
    /// during editing.
    private var cursorReadout: String {
        let p = svc.cursorNormalized
        return String(format: "Cursor: %.0f%%, %.0f%%", p.x * 100, p.y * 100)
    }

    private func paletteColor(at index: Int) -> Color {
        let palette = TouchpadRegion.colorPalette
        let name = palette[index % palette.count]
        switch name {
        case "mint": return .mint
        case "cyan": return .cyan
        case "pink": return .pink
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "indigo": return .indigo
        case "green": return .green
        default: return .gray
        }
    }
}
