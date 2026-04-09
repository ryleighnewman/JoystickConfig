#if os(macOS)
import SwiftUI
import GameController

struct SettingsView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService

    @State private var hasAccessibility = false
    @State private var diagnosticResult = ""
    @State private var showingDiagnostic = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            controllersTab
                .tabItem {
                    Label("Controllers", systemImage: "gamecontroller")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            hasAccessibility = InputSimulator.hasAccessibilityPermission
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(hasAccessibility ? .green : .red)
                    Text("Accessibility Permission")
                    Spacer()
                    if !hasAccessibility {
                        Button("Grant Permission") {
                            InputSimulator.requestAccessibilityPermission()
                            // Open the exact settings pane
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                            // Poll for change
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                hasAccessibility = InputSimulator.hasAccessibilityPermission
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                hasAccessibility = InputSimulator.hasAccessibilityPermission
                            }
                        }
                    } else {
                        Text("Granted")
                            .foregroundStyle(.green)
                    }
                }

                Button("Re-check Permission") {
                    hasAccessibility = InputSimulator.hasAccessibilityPermission
                }
                .font(.caption)
            }

            Section("Troubleshooting") {
                Text("If inputs don't work after granting Accessibility:\n1. Open System Settings > Privacy & Security > Accessibility\n2. Remove old JoystickConfig entries\n3. Click + and add the app from DerivedData or /Applications\n4. Toggle it ON\n\nNote: Rebuilding in Xcode creates a new app signature.\nYou may need to re-grant permission after each rebuild.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Run Diagnostic Test") {
                    diagnosticResult = InputSimulator.runDiagnostic()
                    showingDiagnostic = true
                }

                Button("Test: Move Mouse Right") {
                    InputSimulator.shared.moveMouse(deltaX: 50, deltaY: 0)
                }

                Button("Test: Type 'A'") {
                    InputSimulator.shared.keyDown(4) // HID code for 'A'
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        InputSimulator.shared.keyUp(4)
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $showingDiagnostic) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Diagnostic Results")
                    .font(.headline)

                Text(diagnosticResult)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                Spacer()

                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnosticResult, forType: .string)
                    }
                    Spacer()
                    Button("Done") { showingDiagnostic = false }
                }
            }
            .padding()
            .frame(width: 450, height: 300)
        }
    }

    // MARK: - Controllers

    private var controllersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connected Controllers")
                    .font(.subheadline)
                Spacer()
                Button {
                    controllerService.refreshControllers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            if controllerService.connectedControllers.isEmpty {
                ContentUnavailableView {
                    Label("No Controllers", systemImage: "gamecontroller")
                } description: {
                    Text("Connect a game controller to get started.")
                }
            } else {
                List {
                    ForEach(Array(controllerService.connectedControllers.enumerated()), id: \.offset) { index, controller in
                        HStack {
                            Image(systemName: "gamecontroller.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading) {
                                Text(controller.vendorName ?? "Unknown Controller")
                                    .font(.body)
                                Text("Slot #\(index)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 10) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("JoystickConfig")
                .font(.largeTitle)

            Text("Created by Ryleigh Newman")
                .font(.body)

            Link("ryleighnewman.com", destination: URL(string: "https://ryleighnewman.com")!)
                .font(.body)

            Text("This app is open source.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link("View on GitHub", destination: URL(string: "https://github.com/ryleighnewman/JoystickConfig")!)
                .font(.caption)

            Text("Copyright \u{00A9} 2026 Ryleigh Newman. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Contact me if you ever need anything")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://buymeacoffee.com/ryleighnewman")!) {
                Text("Donate")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.blue)
        }
        .padding()
    }
}
#endif
