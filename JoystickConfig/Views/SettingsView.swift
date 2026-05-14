#if os(macOS)
import SwiftUI
import GameController

struct SettingsView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService

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
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Polling Rate") {
                Text("Controller state is polled at 120 Hz for low-latency input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preset Storage") {
                Text("Presets are saved as JSON in ~/Library/Application Support/JoystickConfig/presets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Show Presets in Finder") {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let presetsDir = appSupport.appendingPathComponent("JoystickConfig/presets", isDirectory: true)
                    NSWorkspace.shared.open(presetsDir)
                }
            }
        }
        .padding()
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
                    Text("Connect an adaptive or game controller to get started.")
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

            Text("Game Controller Configuration")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Configure game controller buttons, triggers, and joysticks\nto behave as keyboard and mouse input on macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

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
        }
        .padding()
    }
}
#endif
