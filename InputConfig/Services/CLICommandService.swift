import Foundation
import CoreFoundation

private let inputConfigCLINotification = "com.ryokojima.inputconfig.local.cli.request"

private func inputConfigCLICallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard let observer else { return }
    let service = Unmanaged<CLICommandService>.fromOpaque(observer).takeUnretainedValue()
    Task { @MainActor in service.processPendingRequests() }
}

private struct CLIRequest: Decodable {
    let schemaVersion: Int
    let requestID: String
    let command: String
    let payload: JSONValue?
    let dryRun: Bool?
}

private struct CLIResponse: Encodable {
    let ok: Bool
    let code: String
    let message: String
    let data: JSONValue?
}

/// Codable JSON tree used by the filesystem CLI protocol. Keeping the wire
/// boundary free of `Any` makes malformed requests fail before they reach a
/// store or service.
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var int: Int? { if case .number(let v) = self, v.rounded() == v { return Int(v) }; return nil }
    var double: Double? { if case .number(let v) = self { return v }; return nil }
}

private struct CLICommandError: Error {
    let code: String
    let message: String
}

@MainActor
final class CLICommandService {
    private let presetStore: PresetStore
    private let mappingEngine: MappingEngine
    private let controllerService: GameControllerService
    private let root: URL
    private let requests: URL
    private let responses: URL
    private var processing = false

    init(presetStore: PresetStore, mappingEngine: MappingEngine,
         controllerService: GameControllerService) {
        self.presetStore = presetStore
        self.mappingEngine = mappingEngine
        self.controllerService = controllerService
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = support.appendingPathComponent("InputConfig/CLI/v1", isDirectory: true)
        requests = root.appendingPathComponent("requests", isDirectory: true)
        responses = root.appendingPathComponent("responses", isDirectory: true)
        try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer,
                                        inputConfigCLICallback, inputConfigCLINotification as CFString,
                                        nil, .deliverImmediately)
        try? Data("{\"schemaVersion\":1,\"ready\":true}".utf8)
            .write(to: root.appendingPathComponent("ready.json"), options: .atomic)
        DispatchQueue.main.async { [weak self] in self?.processPendingRequests() }
    }

    deinit {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer,
                                           CFNotificationName(inputConfigCLINotification as CFString), nil)
    }

    func processPendingRequests() {
        guard !processing else { return }
        processing = true
        let files = (try? FileManager.default.contentsOfDirectory(
            at: requests, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            process(url)
        }
        processing = false

        // A client can receive a response and enqueue its next request while
        // this pass is still unwinding. Its Darwin notification then arrives
        // with `processing == true` and is intentionally ignored. Rescan once
        // after clearing the flag so chained commands (resource get -> patch)
        // cannot strand that second request.
        let hasMore = ((try? FileManager.default.contentsOfDirectory(
            at: requests, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []).contains { $0.pathExtension == "json" }
        if hasMore {
            DispatchQueue.main.async { [weak self] in self?.processPendingRequests() }
        }
    }

    private func process(_ url: URL) {
        var requestID = url.deletingPathExtension().lastPathComponent
        var response: CLIResponse
        do {
            guard let id = UUID(uuidString: requestID), id.uuidString.lowercased() == requestID.lowercased() else {
                throw CLICommandError(code: "invalid_request_id", message: "requestID must be a canonical UUID")
            }
            let data = try Data(contentsOf: url)
            let request = try JSONDecoder().decode(CLIRequest.self, from: data)
            requestID = request.requestID
            guard request.schemaVersion == 1 else {
                throw CLICommandError(code: "unsupported_schema", message: "Only schemaVersion 1 is supported")
            }
            guard request.requestID.lowercased() == id.uuidString.lowercased() else {
                throw CLICommandError(code: "request_id_mismatch", message: "Filename and requestID differ")
            }
            let result = try execute(request.command, payload: request.payload?.object ?? [:], dryRun: request.dryRun ?? false)
            response = CLIResponse(ok: true, code: "ok", message: "OK", data: result)
        } catch let error as CLICommandError {
            response = CLIResponse(ok: false, code: error.code, message: error.message, data: nil)
        } catch {
            response = CLIResponse(ok: false, code: "invalid_request", message: error.localizedDescription, data: nil)
        }
        guard UUID(uuidString: requestID) != nil else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let out = responses.appendingPathComponent(requestID + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(response) { try? data.write(to: out, options: .atomic) }
        try? FileManager.default.removeItem(at: url)
    }

    private func execute(_ command: String, payload: [String: JSONValue], dryRun: Bool) throws -> JSONValue {
        switch command {
        case "status":
            return .object([
                "bundleIdentifier": .string(Bundle.main.bundleIdentifier ?? ""),
                "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
                "engineRunning": .bool(mappingEngine.isRunning),
                "effectivePollHz": .number(Double(mappingEngine.currentPollHz)),
                "autoPollHzByPower": .bool(UserDefaults.standard.bool(forKey: "InputConfig.autoPollHzByPower")),
                "powerSource": SystemStatsService.shared.power.source.map(JSONValue.string) ?? .null,
                "activePresetID": presetStore.activePresetId.map { .string($0.uuidString) } ?? .null,
                "accessibilityTrusted": .bool(AccessibilityPermissionService.shared.isTrusted),
                "loginItemEnabled": .bool(LoginItemService.shared.isEnabled),
                "startupPresetID": UserDefaults.standard.string(forKey: "InputConfig.startup.presetID").map(JSONValue.string) ?? .null,
                "startupError": UserDefaults.standard.string(forKey: "InputConfig.startup.lastError").map(JSONValue.string) ?? .null
            ])
        case "accessibility.request":
            if !dryRun { AccessibilityPermissionService.shared.requestAccess() }
            return .object([
                "requested": .bool(!dryRun),
                "trusted": .bool(AccessibilityPermissionService.shared.isTrusted)
            ])
        case "selftest.run":
            if !dryRun && !TestBenchService.shared.isRunning {
                Task { @MainActor in _ = await TestBenchService.shared.runAll() }
            }
            return .object([
                "started": .bool(!dryRun),
                "running": .bool(TestBenchService.shared.isRunning)
            ])
        case "selftest.status":
            let bench = TestBenchService.shared
            let failed = bench.results.filter { $0.status == .fail }.count
            let passed = bench.results.filter { $0.status == .pass }.count
            return .object([
                "running": .bool(bench.isRunning),
                "passed": .number(Double(passed)),
                "failed": .number(Double(failed)),
                "results": .array(bench.results.map { result in
                    .object([
                        "category": .string(result.category),
                        "name": .string(result.name),
                        "status": .string(result.status.rawValue),
                        "detail": .string(result.detail)
                    ])
                })
            ])
        case "devices.list", "devices.state":
            return deviceState(includeState: command == "devices.state")
        case "preset.list":
            return try encode(presetStore.presets.map { PresetSummary($0) })
        case "preset.show", "preset.export":
            return try encode(resolvePreset(payload))
        case "preset.validate":
            _ = try presetFromPayload(payload)
            return .object(["valid": .bool(true)])
        case "preset.apply", "preset.import":
            let preset = try presetFromPayload(payload)
            if dryRun { return try encode(preset) }
            if let existing = presetStore.presets.first(where: { $0.name == preset.name && $0.id != preset.id }) {
                throw CLICommandError(code: "duplicate_name", message: "Preset name matches \(existing.id.uuidString); select by UUID")
            }
            presetStore.savePreset(preset, forceSnapshot: true)
            if payload["activate"]?.bool == true { activate(preset) }
            return try encode(preset)
        case "preset.create":
            let name = try requiredString(payload, "name")
            if presetStore.presets.contains(where: { $0.name == name }) {
                throw CLICommandError(code: "duplicate_name", message: "A preset named \(name) already exists")
            }
            let preset = Preset(name: name, tag: payload["tag"]?.string ?? "CLI", joysticks: [JoystickMapping(tag: "CLI", inputKind: .controller)])
            if !dryRun { presetStore.savePreset(preset) }
            return try encode(preset)
        case "preset.duplicate":
            let original = try resolvePreset(payload)
            if dryRun { return try encode(original) }
            return try encode(presetStore.duplicatePreset(original))
        case "preset.activate":
            let preset = try resolvePreset(payload)
            if !dryRun { activate(preset) }
            return try encode(PresetSummary(preset))
        case "preset.deactivate":
            if !dryRun { mappingEngine.stop(); presetStore.deactivateAll() }
            return .object(["active": .bool(false)])
        case "preset.delete":
            let preset = try resolvePreset(payload)
            if !dryRun { mappingEngine.stop(); presetStore.deletePreset(preset) }
            return try encode(PresetSummary(preset))
        case "preset.convert":
            let preset = try resolvePreset(payload)
            guard let data = presetStore.exportPresetAsLegacy(preset) else {
                throw CLICommandError(code: "conversion_failed", message: "Preset cannot be represented as legacy JSON")
            }
            return try JSONDecoder().decode(JSONValue.self, from: data)
        case "binding.list":
            let p = try resolvePreset(payload)
            return try encode(p.joysticks.flatMap(\.bindings))
        case "binding.set":
            var p = try resolvePreset(payload)
            guard let value = payload["value"] else { throw missing("value") }
            let binding: BindingModel = try decode(value)
            let slot = payload["slot"]?.int ?? 0
            guard p.joysticks.indices.contains(slot) else { throw CLICommandError(code: "invalid_slot", message: "Joystick slot is out of range") }
            if let i = p.joysticks[slot].bindings.firstIndex(where: { $0.input.serialized == binding.input.serialized }) {
                p.joysticks[slot].bindings[i] = binding
            } else { p.joysticks[slot].bindings.append(binding) }
            if !dryRun { presetStore.savePreset(p, forceSnapshot: true) }
            return try encode(p)
        case "binding.remove":
            var p = try resolvePreset(payload)
            let input = try requiredString(payload, "input")
            for i in p.joysticks.indices { p.joysticks[i].bindings.removeAll { $0.input.serialized == input } }
            if !dryRun { presetStore.savePreset(p, forceSnapshot: true) }
            return try encode(p)
        case "group.list": return try encode(presetStore.groups)
        case "group.create":
            let name = try requiredString(payload, "name")
            if dryRun { return .object(["name": .string(name)]) }
            return .object(["id": .string(presetStore.createGroup(named: name).uuidString), "name": .string(name)])
        case "group.rename", "group.color", "group.move", "group.delete":
            let id = try requiredUUID(payload, "id")
            guard presetStore.groups.contains(where: { $0.id == id }) else { throw notFound("group") }
            if !dryRun {
                if command == "group.rename" { presetStore.renameGroup(id, to: try requiredString(payload, "name")) }
                else if command == "group.color" { presetStore.setGroupColor(id, color: payload["color"]?.string) }
                else if command == "group.move" { presetStore.setGroupParent(id, parentID: optionalUUID(payload["parentID"])) }
                else { presetStore.deleteGroup(id) }
            }
            return .object(["id": .string(id.uuidString)])
        case "settings.get": return settings(payload)
        case "settings.set":
            let key = try checkedSettingKey(payload)
            guard let value = payload["value"] else { throw missing("value") }
            if !dryRun {
                try setDefault(value, for: key)
                if Self.pollSettingKeys.contains(key) { mappingEngine.applyPollRate() }
            }
            return .object(["key": .string(key), "value": value])
        case "settings.reset":
            if payload["key"] == nil {
                let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
                let keys = domain.keys.filter { $0.hasPrefix("InputConfig.") }
                if !dryRun {
                    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
                    mappingEngine.applyPollRate()
                }
                return .object(["reset": .bool(true), "count": .number(Double(keys.count))])
            }
            let key = try checkedSettingKey(payload)
            if !dryRun {
                UserDefaults.standard.removeObject(forKey: key)
                if Self.pollSettingKeys.contains(key) { mappingEngine.applyPollRate() }
            }
            return .object(["key": .string(key), "reset": .bool(true)])
        case "settings.login-item":
            let enabled = payload["enabled"]?.bool ?? false
            if !dryRun && !LoginItemService.shared.setEnabled(enabled) {
                throw CLICommandError(code: "login_item_failed", message: LoginItemService.shared.lastError ?? "Could not update login item")
            }
            return .object(["enabled": .bool(enabled)])
        case "calibration.get": return try encode(TouchpadService.shared.currentCalibration())
        case "calibration.set":
            guard let value = payload["value"] else { throw missing("value") }
            let c: TouchpadCalibration = try decode(value)
            guard c.maxX > c.minX && c.maxY > c.minY else { throw CLICommandError(code: "invalid_calibration", message: "Calibration spans must be positive") }
            if !dryRun { TouchpadService.shared.saveCalibration(c) }
            return try encode(c)
        case "calibration.reset":
            if !dryRun { TouchpadService.shared.saveCalibration(.uncalibrated) }
            return try encode(TouchpadCalibration.uncalibrated)
        case "region.list": return try regionList(payload)
        case "region.apply": return try regionApply(payload, dryRun: dryRun)
        case "region.delete": return try regionDelete(payload, dryRun: dryRun)
        case "trash.list": return try encode(presetStore.snapshotTrashForBackup())
        case "trash.restore":
            let id = try requiredUUID(payload, "id")
            guard let entry = presetStore.recentlyDeleted.first(where: { $0.preset.id == id }) else { throw notFound("trash entry") }
            if !dryRun { _ = presetStore.restoreDeleted(entry) }
            return try encode(entry.preset)
        case "trash.empty":
            if !dryRun { presetStore.emptyTrash() }
            return .object(["emptied": .bool(true)])
        case "stats.show", "stats.export": return try encode(StatsService.shared.stats)
        case "stats.reset":
            if !dryRun { StatsService.shared.resetAll() }
            return .object(["reset": .bool(true)])
        case "backup.export": return try backup()
        case "backup.restore":
            guard let value = payload["value"] else { throw missing("value") }
            return try restoreBackup(value, dryRun: dryRun)
        case "schema": return schema()
        case "resource.get": return try resourceGet(try requiredString(payload, "resource"))
        case "resource.apply":
            guard let value = payload["value"] else { throw missing("value") }
            return try resourceApply(try requiredString(payload, "resource"), value: value, dryRun: dryRun)
        default: throw CLICommandError(code: "unknown_command", message: "Unknown command: \(command)")
        }
    }

    private func activate(_ preset: Preset) {
        presetStore.activatePreset(preset)
        mappingEngine.start(with: preset)
    }

    private func resolvePreset(_ payload: [String: JSONValue]) throws -> Preset {
        if let raw = payload["id"]?.string, let id = UUID(uuidString: raw),
           let p = presetStore.presets.first(where: { $0.id == id }) { return p }
        if let name = payload["name"]?.string {
            let matches = presetStore.presets.filter { $0.name == name }
            if matches.count > 1 { throw CLICommandError(code: "ambiguous_name", message: "Multiple presets have this name; use UUID") }
            if let p = matches.first { return p }
        }
        throw notFound("preset")
    }

    private func presetFromPayload(_ payload: [String: JSONValue]) throws -> Preset {
        guard let value = payload["value"] else { throw missing("value") }
        if value.object?["joysticks"] != nil { return try decode(value) }
        guard let root = value.object else { throw CLICommandError(code: "invalid_preset", message: "Preset value must be an object") }
        let name = root["name"]?.string ?? "DualSense Desktop"
        let specs = root["bindings"]?.array ?? []
        var bindings: [BindingModel] = []
        for spec in specs { bindings.append(contentsOf: try expandBinding(spec)) }
        return Preset(name: name, tag: root["tag"]?.string ?? "DualSense / CLI",
                      joysticks: [JoystickMapping(tag: "PS5 DualSense", bindings: bindings, customName: "DualSense", inputKind: .controller)])
    }

    private func expandBinding(_ value: JSONValue) throws -> [BindingModel] {
        guard let s = value.object, let input = s["input"]?.string, let output = s["output"]?.string else {
            throw CLICommandError(code: "invalid_binding", message: "Each binding needs string input and output")
        }
        let deadzone = s["deadzone"]?.double.map(Float.init)
        let speed = s["speed"]?.int ?? 6
        let variable = s["variableSensitivity"]?.bool
        let turboEnabled = s["turbo"]?.bool ?? s["turboEnabled"]?.bool
        let turboRate = s["turboRate"]?.int
        let holdOutput = s["hold"]?.bool == true
        let invertVertical = s["invertVertical"]?.bool == true
        let curve = SensitivityCurve(rawValue: s["curve"]?.string == "smooth" ? "exponential" : (s["curve"]?.string ?? "linear"))
        func model(_ event: InputEvent, _ actions: [OutputAction], macro: [MacroStep]? = nil) -> BindingModel {
            BindingModel(input: event, outputs: actions, deadzone: deadzone,
                         turboEnabled: turboEnabled, turboRate: turboRate,
                         sensitivityCurve: curve, variableSensitivity: variable,
                         macroSteps: macro, macroInterruptOnRelease: macro == nil ? nil : true,
                         note: s["note"]?.string)
        }
        func action(_ type: OutputType, axis: MouseAxis? = nil, dir: MouseDirection? = nil) -> OutputAction {
            OutputAction(type: type, mouseAxis: axis, mouseDirection: dir, speed: speed)
        }
        let buttons = ["cross": 0, "circle": 1, "square": 2, "triangle": 3,
                       "l1": 4, "r1": 5, "l2-button": 6, "r2-button": 7,
                       "l3": 11, "r3": 12, "touchpad-click": 13]
        if let btn = buttons[input] {
            let (actions, macro) = try outputActions(output, hold: holdOutput)
            return [model(.button(btn), actions, macro: macro)]
        }
        if input == "l2" || input == "r2" {
            let (actions, macro) = try outputActions(output, hold: holdOutput)
            return [model(.axis(input == "l2" ? 4 : 5, direction: .positive), actions, macro: macro)]
        }
        if input.hasPrefix("dpad-") {
            let raw = String(input.dropFirst(5))
            let dirs: [String: HatDirection] = ["up": .up, "right": .right, "down": .down, "left": .left]
            guard let dir = dirs[raw] else { throw CLICommandError(code: "invalid_alias", message: input) }
            let (actions, macro) = try outputActions(output, hold: holdOutput)
            return [model(.hat(0, direction: dir), actions, macro: macro)]
        }
        if input == "left-stick" || input == "right-stick" {
            let base = input == "left-stick" ? 0 : 2
            let outputType: OutputType = output == "cursor" ? .mouseMotion : .mouseWheel
            let negativeVertical: MouseDirection = invertVertical ? .positive : .negative
            let positiveVertical: MouseDirection = invertVertical ? .negative : .positive
            return [
                model(.axis(base, direction: .negative), [action(outputType, axis: .horizontal, dir: .negative)]),
                model(.axis(base, direction: .positive), [action(outputType, axis: .horizontal, dir: .positive)]),
                model(.axis(base + 1, direction: .negative), [action(outputType, axis: .vertical, dir: negativeVertical)]),
                model(.axis(base + 1, direction: .positive), [action(outputType, axis: .vertical, dir: positiveVertical)])
            ]
        }
        if input == "touchpad-finger1" || input == "touchpad-finger2" {
            let finger = input == "touchpad-finger1" ? 0 : 1
            let outputType: OutputType = output == "cursor" ? .mouseMotion : .mouseWheel
            return [
                model(.touchpad(finger: finger, axis: .x, direction: .negative), [action(outputType, axis: .horizontal, dir: .negative)]),
                model(.touchpad(finger: finger, axis: .x, direction: .positive), [action(outputType, axis: .horizontal, dir: .positive)]),
                model(.touchpad(finger: finger, axis: .y, direction: .negative), [action(outputType, axis: .vertical, dir: .negative)]),
                model(.touchpad(finger: finger, axis: .y, direction: .positive), [action(outputType, axis: .vertical, dir: .positive)])
            ]
        }
        throw CLICommandError(code: "invalid_alias", message: "Unknown input alias: \(input)")
    }

    private func outputActions(_ alias: String, hold: Bool = false) throws -> ([OutputAction], [MacroStep]?) {
        let keys = ["enter": 40, "escape": 41, "tab": 43, "space": 44,
                    "arrow-right": 79, "arrow-left": 80, "arrow-down": 81, "arrow-up": 82]
        if let code = keys[alias] { return ([OutputAction(type: .key, keyCode: code)], nil) }
        if alias == "left-click" { return ([OutputAction(type: .mouseButton, mouseButtonIndex: 0)], nil) }
        if alias == "right-click" { return ([OutputAction(type: .mouseButton, mouseButtonIndex: 1)], nil) }
        // Trigger the system Mission Control component directly. A keyboard
        // chord is user-configurable and may be disabled, so it is not a
        // reliable implementation of this semantic action.
        if alias == "mission-control" {
            return ([OutputAction(type: .appAction, appActionKind: .missionControl)], nil)
        }
        let chords: [String: (Int, Int)] = ["command+c": (227, 6), "command+v": (227, 25),
                                            "option+space": (226, 44), "shift+tab": (225, 43),
                                            "command+enter": (227, 40)]
        if let (modifier, key) = chords[alias] {
            // Hold-mode chords use the normal binding lifecycle: all keys go
            // down when the input crosses its threshold and are released in
            // reverse order when it drops below the threshold.
            if hold {
                return ([OutputAction(type: .key, keyCode: modifier),
                         OutputAction(type: .key, keyCode: key)], nil)
            }
            let steps = [MacroStep(action: OutputAction(type: .key, keyCode: modifier), delayMs: 0, holdMs: 0, eventKind: .down),
                         MacroStep(action: OutputAction(type: .key, keyCode: key), delayMs: 10, holdMs: 35, eventKind: .tap),
                         MacroStep(action: OutputAction(type: .key, keyCode: modifier), delayMs: 10, holdMs: 0, eventKind: .up)]
            return ([], steps)
        }
        throw CLICommandError(code: "invalid_alias", message: "Unknown output alias: \(alias)")
    }

    private func deviceState(includeState: Bool) -> JSONValue {
        var rows: [JSONValue] = []
        for (slot, c) in controllerService.connectedControllers.enumerated() {
            var row: [String: JSONValue] = ["slot": .number(Double(slot)), "name": .string(c.vendorName ?? "Controller"), "transport": .string("GameController")]
            if includeState, let s = controllerService.readControllerState(at: slot) {
                row["buttons"] = .object(Dictionary(uniqueKeysWithValues: s.buttons.map { (String($0.key), .number(Double($0.value))) }))
                row["axes"] = .object(Dictionary(uniqueKeysWithValues: s.axes.map { (String($0.key), .number(Double($0.value))) }))
            }
            rows.append(.object(row))
        }
        for (slot, raw) in controllerService.rawHIDGamepadSlots {
            rows.append(.object(["slot": .number(Double(slot)), "name": .string(raw.productName), "transport": .string("RawHID")]))
        }
        return .array(rows)
    }

    private func settings(_ payload: [String: JSONValue]) -> JSONValue {
        if let key = payload["key"]?.string {
            return .object(["key": .string(key), "value": defaultValue(key)])
        }
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let values = domain.filter { $0.key.hasPrefix("InputConfig.") }
        return .object(values.mapValues(settingJSONValue))
    }

    private func defaultValue(_ key: String) -> JSONValue {
        guard let value = UserDefaults.standard.object(forKey: key) else { return .null }
        return settingJSONValue(value)
    }

    private func setDefault(_ value: JSONValue, for key: String) throws {
        if key == "InputConfig.loginItem" {
            guard let enabled = value.bool, LoginItemService.shared.setEnabled(enabled) else {
                throw CLICommandError(code: "login_item_failed", message: LoginItemService.shared.lastError ?? "Invalid login item value")
            }
            return
        }
        if value == .null {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(try settingFoundation(value), forKey: key)
        }
    }

    /// Settings whose changes must rebuild the live controller timer. The GUI
    /// already did this in its onChange handlers; CLI writes previously only
    /// changed UserDefaults, leaving the old cadence active until a restart or
    /// preset reactivation.
    private static let pollSettingKeys: Set<String> = [
        "InputConfig.pollHz",
        "InputConfig.autoPollHzByPower",
        "InputConfig.pollHzOnAC",
        "InputConfig.pollHzOnBattery",
    ]

    private func checkedSettingKey(_ payload: [String: JSONValue]) throws -> String {
        let key = try requiredString(payload, "key")
        guard key.hasPrefix("InputConfig."), !key.contains("/") else {
            throw CLICommandError(code: "invalid_setting_key", message: "Settings keys must start with InputConfig. and contain no slash")
        }
        return key
    }

    private func regionList(_ payload: [String: JSONValue]) throws -> JSONValue {
        switch payload["kind"]?.string ?? "touchpad" {
        case "touchpad": return try encode(TouchpadService.shared.allRegions())
        case "cursor": return try encode(CursorRegionService.shared.allRegions())
        case "stick": return try encode(StickRegionService.shared.regions(forStick: payload["stick"]?.int ?? 0))
        default: throw CLICommandError(code: "invalid_region_kind", message: "kind must be touchpad, cursor, or stick")
        }
    }

    private func regionApply(_ payload: [String: JSONValue], dryRun: Bool) throws -> JSONValue {
        guard let value = payload["value"] else { throw missing("value") }
        let region: TouchpadRegion = try decode(value)
        guard (0...1).contains(region.minX), (0...1).contains(region.maxX), (0...1).contains(region.minY), (0...1).contains(region.maxY), region.maxX > region.minX, region.maxY > region.minY else {
            throw CLICommandError(code: "invalid_region", message: "Region must have a positive rectangle inside 0...1")
        }
        if !dryRun {
            switch payload["kind"]?.string ?? "touchpad" {
            case "touchpad": var all = TouchpadService.shared.allRegions(); all.removeAll { $0.id == region.id }; all.append(region); TouchpadService.shared.saveRegions(all)
            case "cursor": CursorRegionService.shared.upsert(region)
            case "stick": StickRegionService.shared.upsert(region, stickIndex: payload["stick"]?.int ?? 0)
            default: throw CLICommandError(code: "invalid_region_kind", message: "Unknown region kind")
            }
        }
        return try encode(region)
    }

    private func regionDelete(_ payload: [String: JSONValue], dryRun: Bool) throws -> JSONValue {
        let id = try requiredUUID(payload, "id")
        if !dryRun {
            switch payload["kind"]?.string ?? "touchpad" {
            case "touchpad": var all = TouchpadService.shared.allRegions(); all.removeAll { $0.id == id }; TouchpadService.shared.saveRegions(all)
            case "cursor": CursorRegionService.shared.deleteRegion(id)
            case "stick": StickRegionService.shared.delete(id)
            default: throw CLICommandError(code: "invalid_region_kind", message: "Unknown region kind")
            }
        }
        return .object(["id": .string(id.uuidString)])
    }

    private func backup() throws -> JSONValue {
        .object(["schemaVersion": .number(1), "presets": try encode(presetStore.presets),
                 "groups": try encode(presetStore.groups), "settings": settings([:]),
                 "calibration": try encode(TouchpadService.shared.currentCalibration()),
                 "trash": try encode(presetStore.snapshotTrashForBackup())])
    }

    private func restoreBackup(_ value: JSONValue, dryRun: Bool) throws -> JSONValue {
        guard let o = value.object else { throw CLICommandError(code: "invalid_backup", message: "Backup must be an object") }
        let presets: [Preset] = try decode(o["presets"] ?? .array([]))
        let groups: [PresetGroup] = try decode(o["groups"] ?? .array([]))
        let trash: [PresetStore.TrashSnapshot] = try decode(o["trash"] ?? .array([]))
        let calibration: TouchpadCalibration? = o["calibration"].flatMap { try? decode($0) }
        let settingsValue = o["settings"] ?? .object([:])
        guard settingsValue.object != nil else { throw CLICommandError(code: "invalid_backup", message: "Backup settings must be an object") }
        if !dryRun {
            for group in groups { presetStore.upsertGroup(group) }
            for preset in presets { presetStore.savePreset(preset, forceSnapshot: true) }
            for entry in trash { presetStore.restoreTrashFromBackup(preset: entry.preset, deletedAt: entry.deletedAt) }
            if let calibration { TouchpadService.shared.saveCalibration(calibration) }
            _ = try resourceApply("settings", value: settingsValue, dryRun: false)
        }
        return .object(["valid": .bool(true), "presetCount": .number(Double(presets.count)), "groupCount": .number(Double(groups.count)), "trashCount": .number(Double(trash.count))])
    }

    private func schema() -> JSONValue {
        .object(["schemaVersion": .number(1), "commands": .array([
            "status", "accessibility.request", "selftest.run", "selftest.status", "devices.list", "devices.state", "preset.list", "preset.show", "preset.create", "preset.duplicate", "preset.import", "preset.export", "preset.validate", "preset.apply", "preset.patch", "preset.convert", "preset.activate", "preset.deactivate", "preset.delete", "binding.list", "binding.set", "binding.remove", "group.list", "group.create", "group.rename", "group.move", "group.color", "group.delete", "settings.get", "settings.set", "settings.reset", "settings.login-item", "calibration.get", "calibration.set", "calibration.reset", "region.list", "region.apply", "region.delete", "backup.export", "backup.restore", "trash.list", "trash.restore", "trash.empty", "stats.show", "stats.export", "stats.reset", "schema", "resource.get", "resource.apply", "resource.patch"
        ].map(JSONValue.string)), "resources": .array(["presets", "groups", "settings", "calibration", "touchpad-regions", "cursor-regions", "left-stick-regions", "right-stick-regions", "trash", "stats", "backup"].map(JSONValue.string))])
    }

    private func resourceGet(_ name: String) throws -> JSONValue {
        switch name {
        case "presets": return try encode(presetStore.presets)
        case "groups": return try encode(presetStore.groups)
        case "settings": return settings([:])
        case "calibration": return try encode(TouchpadService.shared.currentCalibration())
        case "touchpad-regions": return try encode(TouchpadService.shared.allRegions())
        case "cursor-regions": return try encode(CursorRegionService.shared.allRegions())
        case "left-stick-regions": return try encode(StickRegionService.shared.regions(forStick: 0))
        case "right-stick-regions": return try encode(StickRegionService.shared.regions(forStick: 1))
        case "trash": return try encode(presetStore.snapshotTrashForBackup())
        case "stats": return try encode(StatsService.shared.stats)
        case "backup": return try backup()
        default: throw CLICommandError(code: "unknown_resource", message: "Unknown resource: \(name)")
        }
    }

    private func resourceApply(_ name: String, value: JSONValue, dryRun: Bool) throws -> JSONValue {
        switch name {
        case "presets":
            let values: [Preset] = try decode(value)
            if !dryRun { for old in presetStore.presets { presetStore.hardDeletePreset(old) }; for p in values { presetStore.savePreset(p, forceSnapshot: true) } }
            return try encode(values)
        case "groups":
            let values: [PresetGroup] = try decode(value)
            if !dryRun { for old in presetStore.groups { presetStore.deleteGroup(old.id) }; for g in values { presetStore.upsertGroup(g) } }
            return try encode(values)
        case "settings":
            guard let values = value.object else { throw CLICommandError(code: "validation_failed", message: "settings must be an object") }
            for key in values.keys where !key.hasPrefix("InputConfig.") || key.contains("/") {
                throw CLICommandError(code: "invalid_setting_key", message: "Invalid settings key: \(key)")
            }
            if !dryRun {
                let old = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
                for key in old.keys where key.hasPrefix("InputConfig.") { UserDefaults.standard.removeObject(forKey: key) }
                for (key, setting) in values { try setDefault(setting, for: key) }
            }
            return value
        case "calibration": return try execute("calibration.set", payload: ["value": value], dryRun: dryRun)
        case "touchpad-regions", "cursor-regions", "left-stick-regions", "right-stick-regions":
            let values: [TouchpadRegion] = try decode(value)
            if !dryRun {
                if name == "touchpad-regions" { TouchpadService.shared.saveRegions([]) }
                else if name == "cursor-regions" { for old in CursorRegionService.shared.allRegions() { CursorRegionService.shared.deleteRegion(old.id) } }
                else { for old in StickRegionService.shared.regions(forStick: name == "right-stick-regions" ? 1 : 0) { StickRegionService.shared.delete(old.id) } }
            }
            for r in values { _ = try regionApply(["kind": .string(name == "touchpad-regions" ? "touchpad" : name == "cursor-regions" ? "cursor" : "stick"), "stick": .number(name == "right-stick-regions" ? 1 : 0), "value": try encode(r)], dryRun: dryRun) }
            return try encode(values)
        case "backup": return try restoreBackup(value, dryRun: dryRun)
        default: throw CLICommandError(code: "read_only_resource", message: "Resource is read-only or must be changed through settings commands")
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: e.encode(value))
    }
    private func decode<T: Decodable>(_ value: JSONValue) throws -> T {
        let e = JSONEncoder(); let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        do { return try d.decode(T.self, from: e.encode(value)) }
        catch { throw CLICommandError(code: "validation_failed", message: error.localizedDescription) }
    }
    private func foundation(_ value: JSONValue) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// UserDefaults is a property-list store, not a JSON store. Convert its
    /// Date/Data values explicitly so all-settings backups stay lossless and
    /// non-JSON defaults never raise an Objective-C JSONSerialization exception.
    private func settingJSONValue(_ value: Any) -> JSONValue {
        if let value = value as? Date {
            return .object(["$type": .string("date"),
                            "value": .string(ISO8601DateFormatter().string(from: value))])
        }
        if let value = value as? Data {
            return .object(["$type": .string("data"),
                            "base64": .string(value.base64EncodedString())])
        }
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        }
        if let value = value as? [Any] { return .array(value.map(settingJSONValue)) }
        if let value = value as? [String: Any] { return .object(value.mapValues(settingJSONValue)) }
        return .string(String(describing: value))
    }

    private func settingFoundation(_ value: JSONValue) throws -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return try values.map(settingFoundation)
        case .object(let values):
            if values["$type"]?.string == "date", let raw = values["value"]?.string,
               let date = ISO8601DateFormatter().date(from: raw) { return date }
            if values["$type"]?.string == "data", let raw = values["base64"]?.string,
               let data = Data(base64Encoded: raw) { return data }
            var result: [String: Any] = [:]
            for (key, nested) in values { result[key] = try settingFoundation(nested) }
            return result
        }
    }
    private func requiredString(_ p: [String: JSONValue], _ key: String) throws -> String {
        guard let value = p[key]?.string, !value.isEmpty else { throw missing(key) }; return value
    }
    private func requiredUUID(_ p: [String: JSONValue], _ key: String) throws -> UUID {
        guard let raw = p[key]?.string, let id = UUID(uuidString: raw) else { throw CLICommandError(code: "invalid_uuid", message: "\(key) must be a UUID") }; return id
    }
    private func optionalUUID(_ value: JSONValue?) -> UUID? { value?.string.flatMap(UUID.init(uuidString:)) }
    private func missing(_ key: String) -> CLICommandError { CLICommandError(code: "missing_argument", message: "Missing \(key)") }
    private func notFound(_ what: String) -> CLICommandError { CLICommandError(code: "not_found", message: "No matching \(what)") }
}

private struct PresetSummary: Encodable {
    let id: UUID; let name: String; let isActive: Bool; let modifiedAt: Date; let bindingCount: Int
    init(_ p: Preset) { id = p.id; name = p.name; isActive = p.isActive; modifiedAt = p.modifiedAt; bindingCount = p.joysticks.reduce(0) { $0 + $1.bindings.count } }
}
