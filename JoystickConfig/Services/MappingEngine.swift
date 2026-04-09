import Foundation
import Combine

/// The core engine that reads controller inputs and fires output actions.
/// 120Hz polling with debug logging capability.
@MainActor
class MappingEngine: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var activePreset: Preset?
    @Published var activeInputs: Set<String> = []
    @Published var debugLog: [(text: String, joystickIndex: Int?)] = []  // Rolling debug log visible in UI

    private var controllerService: GameControllerService
    private var pollTimer: Timer?

    private var activeStates: [Int: Set<String>] = [:]
    private let defaultAxisThreshold: Float = 0.25
    private let hatThreshold: Float = 0.5

    // Toggle mode state: tracks which bindings are currently toggled on
    private var toggleStates: [String: Bool] = [:]
    // Turbo state: tracks last fire time for turbo bindings
    private var turboTimestamps: [String: Date] = [:]
    // Cache of serialized input keys to avoid repeated string allocations at 120Hz
    private var serializedKeyCache: [UUID: String] = [:]

    private var debugEnabled = true
    private var debugLineCount = 0

    init(controllerService: GameControllerService) {
        self.controllerService = controllerService
    }

    // MARK: - Start / Stop

    func start(with preset: Preset) {
        guard !preset.joysticks.isEmpty else { return }

        activePreset = preset
        isRunning = true
        activeStates.removeAll()
        activeInputs.removeAll()
        toggleStates.removeAll()
        turboTimestamps.removeAll()
        serializedKeyCache.removeAll()
        debugLog.removeAll()
        debugLineCount = 0

        for i in preset.joysticks.indices {
            activeStates[i] = Set<String>()
        }

        log("Engine started with preset: \(preset.name)")
        log("Joysticks: \(preset.joysticks.count), Total bindings: \(preset.joysticks.flatMap(\.bindings).count)")
        log("Connected controllers: \(controllerService.connectedControllers.count)")

        for (i, ctrl) in controllerService.connectedControllers.enumerated() {
            log("  Controller \(i): \(ctrl.vendorName ?? "Unknown"), hasExtendedGamepad: \(ctrl.extendedGamepad != nil)")
        }

        let pollInterval: TimeInterval = 1.0 / 120.0
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollControllers()
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isRunning = false
        InputSimulator.shared.releaseAll()
        activeStates.removeAll()
        activeInputs.removeAll()
        activePreset = nil
        log("Engine stopped")
    }

    // MARK: - Debug Logging

    private func log(_ message: String, joystick: Int? = nil) {
        debugLineCount += 1
        let entry = "[\(debugLineCount)] \(message)"
        debugLog.append((text: entry, joystickIndex: joystick))
        // Keep last 50 entries
        if debugLog.count > 50 {
            debugLog.removeFirst()
        }
        #if DEBUG
        print("[MappingEngine] \(message)")
        #endif
    }

    // MARK: - Polling

    private var pollCount = 0

    private func pollControllers() {
        guard let preset = activePreset else { return }
        pollCount += 1

        for (joystickIndex, joystickMapping) in preset.joysticks.enumerated() {
            guard let state = controllerService.readControllerState(at: joystickIndex) else {
                // Log once every 120 polls (1 second)
                if pollCount % 120 == 1 {
                    log("No controller state for joystick \(joystickIndex)", joystick: joystickIndex)
                }
                continue
            }

            // Log raw state once per second for debugging
            if pollCount % 120 == 1 {
                let activeButtons = state.buttons.filter { $0.value > 0.5 }.map { "btn\($0.key)" }
                let activeAxes = state.axes.filter { abs($0.value) > defaultAxisThreshold }.map { "axi\($0.key)=\(String(format: "%.2f", $0.value))" }
                if !activeButtons.isEmpty || !activeAxes.isEmpty {
                    log("Raw state J\(joystickIndex): \(activeButtons + activeAxes)", joystick: joystickIndex)
                }
            }

            var currentlyActive = Set<String>()

            for binding in joystickMapping.bindings {
                let isActive = checkInput(binding.input, state: state, binding: binding)
                let inputKey = cachedKey(for: binding)
                let bindKey = "\(joystickIndex):\(inputKey)"

                if isActive {
                    currentlyActive.insert(inputKey)
                }

                let wasActive = activeStates[joystickIndex]?.contains(inputKey) ?? false

                if binding.toggleMode == true {
                    // Toggle mode: press toggles on/off
                    if isActive && !wasActive {
                        let isToggledOn = toggleStates[bindKey] ?? false
                        if isToggledOn {
                            log("TOGGLE OFF: \(inputKey)", joystick: joystickIndex)
                            fireOutputs(binding.outputs, press: false)
                            toggleStates[bindKey] = false
                        } else {
                            log("TOGGLE ON: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                            fireOutputs(binding.outputs, press: true)
                            toggleStates[bindKey] = true
                        }
                    }
                    // Keep firing continuous outputs while toggled on
                    if toggleStates[bindKey] == true {
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: state, binding: binding)
                    }
                } else if binding.turboEnabled == true {
                    // Turbo mode: rapid fire while held
                    if isActive {
                        if !wasActive {
                            log("TURBO START: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                        }
                        let rate = binding.turboRate ?? 10
                        let interval = 1.0 / Double(rate)
                        let now = Date()
                        let lastFire = turboTimestamps[bindKey] ?? .distantPast
                        if now.timeIntervalSince(lastFire) >= interval {
                            fireOutputs(binding.outputs, press: true)
                            // Schedule release after half the interval
                            DispatchQueue.main.asyncAfter(deadline: .now() + interval * 0.4) { [weak self] in
                                self?.fireOutputs(binding.outputs, press: false)
                            }
                            turboTimestamps[bindKey] = now
                        }
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: state, binding: binding)
                    } else if wasActive {
                        log("TURBO END: \(inputKey)", joystick: joystickIndex)
                        fireOutputs(binding.outputs, press: false)
                        turboTimestamps.removeValue(forKey: bindKey)
                    }
                } else {
                    // Normal mode
                    if isActive && !wasActive {
                        log("PRESS: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                        // Check for macro
                        if let steps = binding.macroSteps, !steps.isEmpty {
                            executeMacro(steps, joystickIndex: joystickIndex)
                        } else if (binding.repeatCount ?? 1) > 1 {
                            fireWithRepeat(binding)
                        } else {
                            fireOutputs(binding.outputs, press: true)
                        }
                    } else if !isActive && wasActive {
                        log("RELEASE: \(inputKey)", joystick: joystickIndex)
                        if binding.macroSteps == nil && (binding.repeatCount ?? 1) <= 1 {
                            fireOutputs(binding.outputs, press: false)
                        }
                    } else if isActive {
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: state, binding: binding)
                    }
                }
            }

            activeStates[joystickIndex] = currentlyActive
        }

        // Update active inputs for UI highlighting
        var allActive = Set<String>()
        for (_, states) in activeStates {
            allActive.formUnion(states)
        }
        if allActive != activeInputs {
            activeInputs = allActive
        }
    }

    /// Returns cached serialized key for a binding's input to avoid string allocations in 120Hz loop
    private func cachedKey(for binding: BindingModel) -> String {
        if let cached = serializedKeyCache[binding.id] { return cached }
        let key = binding.input.serialized
        serializedKeyCache[binding.id] = key
        return key
    }

    // MARK: - Input Checking

    private func checkInput(_ input: InputEvent, state: ControllerState, binding: BindingModel? = nil) -> Bool {
        let axisThreshold = binding?.deadzone ?? defaultAxisThreshold

        switch input.type {
        case .button:
            return (state.buttons[input.index] ?? 0) > 0.5

        case .axis:
            guard var value = state.axes[input.index] else { return false }
            if binding?.invertAxis == true { value = -value }
            switch input.axisDirection {
            case .positive:
                return value > axisThreshold
            case .negative:
                return value < -axisThreshold
            case .none:
                return abs(value) > axisThreshold
            }

        case .hat:
            guard let hat = state.hats[input.index] else { return false }
            switch input.hatDirection {
            case .up:
                return hat.y > hatThreshold
            case .down:
                return hat.y < -hatThreshold
            case .left:
                return hat.x < -hatThreshold
            case .right:
                return hat.x > hatThreshold
            case .none:
                return false
            }
        }
    }

    // MARK: - Output Firing

    private func fireOutputs(_ outputs: [OutputAction], press: Bool) {
        for output in outputs {
            switch output.type {
            case .key:
                if let code = output.keyCode {
                    if press {
                        InputSimulator.shared.keyDown(code)
                    } else {
                        InputSimulator.shared.keyUp(code)
                    }
                }

            case .mouseButton:
                if let btn = output.mouseButtonIndex {
                    if press {
                        InputSimulator.shared.mouseButtonDown(btn)
                    } else {
                        InputSimulator.shared.mouseButtonUp(btn)
                    }
                }

            case .mouseWheelStep:
                if press, let axis = output.mouseAxis, let dir = output.mouseDirection {
                    InputSimulator.shared.scrollWheelStep(axis: axis, direction: dir)
                }

            case .mouseMotion, .mouseWheel:
                break
            }
        }
    }

    /// Execute a macro sequence asynchronously
    private func executeMacro(_ steps: [MacroStep], joystickIndex: Int) {
        log("MACRO: executing \(steps.count) steps", joystick: joystickIndex)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for step in steps {
                // Pre-step delay
                if step.delayMs > 0 {
                    Thread.sleep(forTimeInterval: Double(step.delayMs) / 1000.0)
                }
                // Press
                DispatchQueue.main.async {
                    self?.fireOutputs([step.action], press: true)
                }
                // Hold
                if step.holdMs > 0 {
                    Thread.sleep(forTimeInterval: Double(step.holdMs) / 1000.0)
                }
                // Release
                DispatchQueue.main.async {
                    self?.fireOutputs([step.action], press: false)
                }
            }
        }
    }

    /// Execute outputs with repeat count
    private func fireWithRepeat(_ binding: BindingModel) {
        let count = binding.repeatCount ?? 1
        let delayMs = binding.repeatDelayMs ?? 100

        if count <= 1 {
            fireOutputs(binding.outputs, press: true)
            return
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for i in 0..<count {
                DispatchQueue.main.async {
                    self?.fireOutputs(binding.outputs, press: true)
                }
                Thread.sleep(forTimeInterval: 0.05)
                DispatchQueue.main.async {
                    self?.fireOutputs(binding.outputs, press: false)
                }
                if i < count - 1 {
                    Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
                }
            }
        }
    }

    private func fireContinuousOutputs(_ outputs: [OutputAction], input: InputEvent, state: ControllerState, binding: BindingModel? = nil) {
        for output in outputs {
            switch output.type {
            case .mouseMotion:
                guard let axis = output.mouseAxis, let dir = output.mouseDirection else { continue }
                let speed = output.speed ?? 6

                var magnitude: Float = 1.0
                if input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
                    magnitude = min(abs(axisValue), 1.0)
                    // Apply sensitivity curve
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                }

                let scaledSpeed = Int(Float(speed) * magnitude)
                var deltaX = 0
                var deltaY = 0

                switch (axis, dir) {
                case (.horizontal, .positive): deltaX = scaledSpeed
                case (.horizontal, .negative): deltaX = -scaledSpeed
                case (.vertical, .positive): deltaY = scaledSpeed
                case (.vertical, .negative): deltaY = -scaledSpeed
                }

                InputSimulator.shared.moveMouse(deltaX: deltaX, deltaY: deltaY)

            case .mouseWheel:
                guard let axis = output.mouseAxis, let dir = output.mouseDirection else { continue }
                let speed = output.speed ?? 6

                var magnitude: Float = 1.0
                if input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
                    magnitude = min(abs(axisValue), 1.0)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                }

                let scaledSpeed = Int32(Float(speed) * magnitude)
                var deltaX: Int32 = 0
                var deltaY: Int32 = 0

                switch (axis, dir) {
                case (.horizontal, .positive): deltaX = scaledSpeed
                case (.horizontal, .negative): deltaX = -scaledSpeed
                case (.vertical, .positive): deltaY = scaledSpeed
                case (.vertical, .negative): deltaY = -scaledSpeed
                }

                InputSimulator.shared.scrollWheel(deltaX: deltaX, deltaY: deltaY)

            default:
                break
            }
        }
    }
}
