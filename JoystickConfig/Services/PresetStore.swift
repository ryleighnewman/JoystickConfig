import Foundation
import SwiftUI

/// Manages loading, saving, and organizing presets
@MainActor
class PresetStore: ObservableObject {
    @Published var presets: [Preset] = []
    @Published var activePresetId: UUID?

    private let presetsDirectory: URL
    private let legacyPresetsDirectory: URL?

    init() {
        // App presets directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("JoystickConfig", isDirectory: true)
        self.presetsDirectory = appDir.appendingPathComponent("presets", isDirectory: true)

        // Legacy Joystick Mapper presets directory
        let legacyDir = appSupport.appendingPathComponent("Joystick Mapper", isDirectory: true)
            .appendingPathComponent("presets", isDirectory: true)
        self.legacyPresetsDirectory = FileManager.default.fileExists(atPath: legacyDir.path) ? legacyDir : nil

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)

        loadPresets()
    }

    // MARK: - Loading

    func loadPresets() {
        var loaded: [Preset] = []

        // Load native format presets
        if let files = try? FileManager.default.contentsOfDirectory(at: presetsDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let preset = try? JSONDecoder().decode(Preset.self, from: data) {
                    loaded.append(preset)
                }
            }
        }

        // If no presets found, load examples
        if loaded.isEmpty {
            loaded = ExamplePresets.all
            for preset in loaded {
                savePresetToDisk(preset)
            }
        }

        // Always start with nothing active
        for i in loaded.indices {
            loaded[i].isActive = false
        }
        presets = loaded.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Re-seed example presets (adds any missing examples without duplicating)
    func reseedExamplePresets() {
        let examples = ExamplePresets.all
        let existingNames = Set(presets.map { $0.name })

        for example in examples {
            if !existingNames.contains(example.name) {
                savePreset(example)
            }
        }
    }

    // MARK: - Saving

    /// Save to disk only (no array update)
    private func savePresetToDisk(_ preset: Preset) {
        var mutable = preset
        mutable.modifiedAt = Date()
        let fileURL = presetsDirectory.appendingPathComponent(mutable.filename)
        if let data = try? JSONEncoder().encode(mutable) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func savePreset(_ preset: Preset) {
        var mutable = preset
        mutable.modifiedAt = Date()

        let fileURL = presetsDirectory.appendingPathComponent(mutable.filename)
        if let data = try? JSONEncoder().encode(mutable) {
            try? data.write(to: fileURL, options: .atomic)
        }

        if let index = presets.firstIndex(where: { $0.id == mutable.id }) {
            presets[index] = mutable
        } else {
            presets.insert(mutable, at: 0)
        }
    }

    // MARK: - CRUD

    func createPreset() -> Preset {
        let preset = Preset(name: "New Preset", joysticks: [JoystickMapping(tag: "Add bindings here")])
        savePreset(preset)
        return preset
    }

    func deletePreset(_ preset: Preset) {
        if preset.id == activePresetId {
            deactivateAll()
        }
        presets.removeAll { $0.id == preset.id }
        let fileURL = presetsDirectory.appendingPathComponent(preset.filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func duplicatePreset(_ preset: Preset) -> Preset {
        var clone = preset
        clone = Preset(
            name: "\(preset.name) (Copy)",
            tag: preset.tag,
            joysticks: preset.joysticks,
            filename: Preset.generateFilename(),
            isActive: false
        )
        savePreset(clone)
        return clone
    }

    // MARK: - Reordering

    func movePresets(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Activation

    func activatePreset(_ preset: Preset) {
        deactivateAll()
        activePresetId = preset.id
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index].isActive = true
        }
    }

    func deactivateAll() {
        activePresetId = nil
        for i in presets.indices {
            presets[i].isActive = false
        }
    }

    func togglePreset(_ preset: Preset) {
        if preset.isActive {
            deactivateAll()
        } else {
            activatePreset(preset)
        }
    }

    // MARK: - Import / Export

    func importLegacyPreset(from url: URL) -> Preset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard var preset = Preset.fromLegacyJSON(data, filename: Preset.generateFilename()) else { return nil }
        preset.filename = Preset.generateFilename()
        savePreset(preset)
        return preset
    }

    func importLegacyPresetsFromOriginalApp() -> Int {
        guard let legacyDir = legacyPresetsDirectory else { return 0 }
        guard let files = try? FileManager.default.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) else { return 0 }

        var count = 0
        for file in files where file.pathExtension == "txt" {
            if importLegacyPreset(from: file) != nil {
                count += 1
            }
        }
        return count
    }

    func exportPresetAsLegacy(_ preset: Preset) -> Data? {
        return preset.toLegacyJSON()
    }

    func exportPresetToFile(_ preset: Preset, to url: URL) {
        if let data = preset.toLegacyJSON() {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Conversion

    func convertPreset(_ preset: Preset, from source: ControllerType, to destination: ControllerType) -> Preset {
        var converted = ControllerType.convert(preset: preset, from: source, to: destination)
        converted.filename = Preset.generateFilename()
        savePreset(converted)
        return converted
    }
}
