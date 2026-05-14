import Foundation
import GameController

/// Controls DualSense / DualShock 4 light bars by invoking a helper tool
/// that runs as a separate process, kills the gamecontrolleragentd to release
/// the HID device, and sends the output report matching HIDAPI/SDL2 format.
class HIDLightController {
    nonisolated(unsafe) static let shared = HIDLightController()

    private let queue = DispatchQueue(label: "com.joystickconfig.hidlight")

    private init() {}

    /// Set light color with brightness. Brightness: 0=off, 1=dim, 2=bright.
    func setLightColor(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8 = 2) {
        queue.async { [weak self] in
            self?.runHelper(red: red, green: green, blue: blue, brightness: brightness)
        }
    }

    private func runHelper(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8) {
        guard let helperURL = helperPath() else {
            #if DEBUG
            print("[HIDLight] LightHelper not found in bundle")
            #endif
            return
        }

        let task = Process()
        task.executableURL = helperURL
        task.arguments = [String(red), String(green), String(blue), String(brightness)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            #if DEBUG
            print("[HIDLight] Helper launch failed: \(error)")
            #endif
        }
    }

    private func helperPath() -> URL? {
        // App bundle MacOS directory
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("LightHelper") {
            if FileManager.default.isExecutableFile(atPath: bundlePath.path) {
                return bundlePath
            }
        }
        // Resources
        if let resourcePath = Bundle.main.url(forResource: "LightHelper", withExtension: nil) {
            return resourcePath
        }
        // Development fallback
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LightHelper/LightHelper")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }
        return nil
    }
}
