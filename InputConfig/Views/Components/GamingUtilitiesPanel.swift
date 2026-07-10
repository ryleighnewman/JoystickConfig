import SwiftUI
import AppKit

/// Settings sub-panel for cursor-related quality-of-life options that
/// make playing games on macOS less painful. All features are off by
/// default; flipping a toggle here writes through to the persisted
/// state in `CursorGuardService` (which itself reads from
/// UserDefaults so the choices survive launches).
struct GamingUtilitiesPanel: View {
    @ObservedObject private var guardSvc = CursorGuardService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("These are global defaults used when a preset doesn't set its own. Per-preset overrides live in the preset editor's Automation & Gaming Utilities panel - that's the right place for game-specific choices. Nothing here changes macOS-wide settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // --- Edge confine ---
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $guardSvc.edgeConfineEnabled) {
                    Label("Confine cursor away from screen edges",
                          systemImage: "rectangle.inset.filled")
                }
                if guardSvc.edgeConfineEnabled {
                    HStack {
                        Text("Buffer:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $guardSvc.edgeBufferPx, in: 1...200, step: 1) {
                            EmptyView()
                        }
                        Text("\(Int(guardSvc.edgeBufferPx)) px")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    Text("FPS / 3D games keep reading mouse delta even when the cursor is parked at the screen edge - they don't, but they should. This forces the cursor inside by the buffer distance.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // --- Auto-recenter ---
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $guardSvc.autoRecenterEnabled) {
                    Label("Auto-recenter cursor",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                if guardSvc.autoRecenterEnabled {
                    HStack {
                        Text("Interval:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $guardSvc.recenterIntervalMs, in: 50...2000, step: 10) {
                            EmptyView()
                        }
                        Text("\(Int(guardSvc.recenterIntervalMs)) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    HStack {
                        Spacer()
                        Button {
                            guardSvc.warpToAnchor()
                        } label: {
                            Label("Recenter now", systemImage: "scope")
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        .help("Teleport the cursor to the centre of the current screen.")
                    }
                    Text("Periodically teleports the cursor to the centre of whichever screen it's on. Pair with edge-confine for games whose camera stops moving when the cursor hits an edge.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // --- Cursor hide while engine running ---
            Toggle(isOn: $guardSvc.hideCursorWhileEngineRunning) {
                Label("Hide system cursor while a preset is active",
                      systemImage: "cursorarrow.slash")
            }
            Text("When you start a preset, the floating cursor disappears - the controller is driving input anyway, so the visible cursor is just noise. Restored on stop or app quit.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // --- Sensitivity multiplier (currently informational) ---
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Cursor sensitivity multiplier",
                          systemImage: "speedometer")
                        .font(.callout)
                    Spacer()
                    Text(String(format: "×%.2f", guardSvc.sensitivityMultiplier))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $guardSvc.sensitivityMultiplier, in: 0.1...5.0, step: 0.05) {
                    EmptyView()
                }
                Text("Applied on top of macOS's tracking speed. Affects only the cursor warp engine uses for binding 'Mouse move' outputs; doesn't touch your system pointer-speed slider.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Quick status banner so the user can confirm the service
            // is wired up to the engine.
            if guardSvc.engineActive {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Engine is active. Cursor tools above are live.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }
}
