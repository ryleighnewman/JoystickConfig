import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let presetStore = PresetStore()
    let controllerService = GameControllerService()
    lazy var mappingEngine = MappingEngine(controllerService: controllerService)
}

@main
struct JoystickConfig: App {
    @StateObject private var appState = AppState()
    @State private var hasAccessibility = false
    @State private var accessibilityTimer: Timer?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
                .environmentObject(appState.mappingEngine)
                .sheet(isPresented: .constant(!hasAccessibility)) {
                    accessibilitySheet
                        .interactiveDismissDisabled()
                }
                .onAppear {
                    hasAccessibility = InputSimulator.hasAccessibilityPermission
                    startAccessibilityPolling()
                }
                .onDisappear {
                    accessibilityTimer?.invalidate()
                }
        }
        .defaultSize(width: 1300, height: 750)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Preset") {
                    _ = appState.presetStore.createPreset()
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Show Presets in Finder") {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let presetsDir = appSupport.appendingPathComponent("JoystickConfig/presets", isDirectory: true)
                    NSWorkspace.shared.open(presetsDir)
                }
            }

            CommandGroup(before: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                    )
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
        }
    }

    // MARK: - Accessibility Gate

    private var accessibilitySheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Accessibility Permission Required")
                .font(.title2)

            Text("JoystickConfig needs Accessibility permission to simulate\nkeyboard and mouse input from your game controller.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("System Settings > Privacy & Security > Accessibility")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button {
                    openAccessibilitySettings()
                } label: {
                    Label("Open Accessibility Settings", systemImage: "gear")
                        .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Re-check") {
                    hasAccessibility = InputSimulator.hasAccessibilityPermission
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 4)

            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                Text("Waiting for permission...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .frame(width: 500)
    }

    private func openAccessibilitySettings() {
        // First prompt macOS to add us to the list
        InputSimulator.requestAccessibilityPermission()

        // Then open the exact Accessibility pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let granted = InputSimulator.hasAccessibilityPermission
                if granted != hasAccessibility {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        hasAccessibility = granted
                    }
                }
            }
        }
        RunLoop.main.add(accessibilityTimer!, forMode: .common)
    }
}
