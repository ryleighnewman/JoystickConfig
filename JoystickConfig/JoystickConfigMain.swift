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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
                .environmentObject(appState.mappingEngine)
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

            CommandGroup(replacing: .help) {
                Button("JoystickConfig Help") {
                    HelpGuideWindowController.shared.show()
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
        }
    }
}
