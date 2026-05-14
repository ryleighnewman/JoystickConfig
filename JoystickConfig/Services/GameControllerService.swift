import Foundation
import GameController
import Combine

/// Readable info about a connected controller
struct ControllerInfo {
    var name: String
    var productCategory: String
    var hasExtendedGamepad: Bool
    var hasLight: Bool
    var hasBattery: Bool
    var batteryLevel: Float?
    var batteryState: String?
    var buttonCount: Int
    var axisCount: Int
    var supportsMotion: Bool
    var connectedAt: Date = Date()
    var hasTouchpad: Bool = false
    var hasMicroGamepad: Bool = false
    var hasAdaptiveTriggers: Bool = false
    var physicalButtonNames: [String] = []
}

/// Represents the current state of a connected controller
struct ControllerState {
    var buttons: [Int: Float] = [:]   // button index -> value (0.0 or 1.0)
    var axes: [Int: Float] = [:]      // axis index -> value (-1.0 to 1.0)
    var hats: [Int: (x: Float, y: Float)] = [:] // hat index -> (x, y) direction
}

/// Manages game controller detection and input reading
@MainActor
class GameControllerService: ObservableObject {
    @Published var connectedControllers: [GCController] = []
    @Published var controllerNames: [Int: String] = [:]
    @Published var controllerDetails: [Int: ControllerInfo] = [:]
    @Published var lightColors: [Int: (r: Float, g: Float, b: Float)] = [:]
    @Published var lightBrightness: [Int: UInt8] = [:] // 0=off, 1=dim, 2=bright
    @Published var lastInput: (joystickIndex: Int, inputEvent: InputEvent)?
    @Published var isScanning: Bool = false

    /// Cached mapping of physical profile button name -> button index for each controller slot.
    /// Built once on connection, used every poll frame to avoid re-sorting/re-matching at 120Hz.
    private var cachedExtraButtons: [Int: [(GCControllerButtonInput, Int)]] = [:]

    private var pollTimer: Timer?
    private var detailsTimer: Timer?
    private var scanCallback: ((InputEvent) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupControllerNotifications()
        refreshControllers()
        startDetailsPolling()
    }

    /// Periodically refresh battery level and other dynamic details
    private func startDetailsPolling() {
        detailsTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                for (index, controller) in self.connectedControllers.enumerated() {
                    self.controllerDetails[index] = self.buildControllerInfo(controller)
                }
            }
        }
    }

    // MARK: - Controller Discovery

    private func setupControllerNotifications() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshControllers()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshControllers()
            }
        }
    }

    /// Colors assigned to each controller slot
    static let slotColors: [(r: Float, g: Float, b: Float)] = [
        (0.2, 0.8, 0.4),  // green
        (0.6, 0.3, 0.8),  // purple
        (0.9, 0.3, 0.3),  // red
        (0.9, 0.6, 0.2),  // orange
        (0.2, 0.8, 0.8),  // cyan
        (0.9, 0.4, 0.6),  // pink
    ]

    func refreshControllers() {
        connectedControllers = GCController.controllers()
        controllerNames.removeAll()
        controllerDetails.removeAll()
        cachedExtraButtons.removeAll()
        for (index, controller) in connectedControllers.enumerated() {
            cacheExtraButtons(for: controller, at: index)
            controllerNames[index] = controller.vendorName ?? "Controller \(index)"
            controllerDetails[index] = buildControllerInfo(controller)

            // Set light immediately
            setControllerLight(at: index)

            // Retry after a delay since some controllers need time after connection
            let idx = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setControllerLight(at: idx)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.setControllerLight(at: idx)
                // Update details again (battery may not be ready immediately)
                if idx < (self?.connectedControllers.count ?? 0) {
                    self?.controllerDetails[idx] = self?.buildControllerInfo(controller)
                }
            }
        }
    }

    private func buildControllerInfo(_ controller: GCController) -> ControllerInfo {
        let profile = controller.physicalInputProfile
        var batteryLevel: Float?
        var batteryState: String?
        if let battery = controller.battery {
            batteryLevel = battery.batteryLevel
            switch battery.batteryState {
            case .charging: batteryState = "Charging"
            case .full: batteryState = "Full"
            case .discharging: batteryState = "Discharging"
            case .unknown: batteryState = "Unknown"
            @unknown default: batteryState = "Unknown"
            }
        }
        let buttonNames = Array(profile.buttons.keys).sorted()
        let hasTouchpad = buttonNames.contains(where: { $0.lowercased().contains("touchpad") })
        let pid = controller.productCategory

        return ControllerInfo(
            name: controller.vendorName ?? "Unknown Controller",
            productCategory: pid,
            hasExtendedGamepad: controller.extendedGamepad != nil,
            hasLight: controller.light != nil,
            hasBattery: controller.battery != nil,
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            buttonCount: profile.buttons.count,
            axisCount: profile.axes.count,
            supportsMotion: controller.motion != nil,
            connectedAt: Date(),
            hasTouchpad: hasTouchpad,
            hasMicroGamepad: controller.microGamepad != nil,
            hasAdaptiveTriggers: pid.lowercased().contains("dualsense"),
            physicalButtonNames: buttonNames
        )
    }

    /// Pre-compute the mapping of extra physical profile buttons for a controller.
    /// This runs once on connection so readControllerState doesn't rebuild it every frame.
    private func cacheExtraButtons(for controller: GCController, at index: Int) {
        guard let gamepad = controller.extendedGamepad else {
            cachedExtraButtons[index] = []
            return
        }

        var handledObjects = Set<ObjectIdentifier>()
        handledObjects.insert(ObjectIdentifier(gamepad.buttonA))
        handledObjects.insert(ObjectIdentifier(gamepad.buttonB))
        handledObjects.insert(ObjectIdentifier(gamepad.buttonX))
        handledObjects.insert(ObjectIdentifier(gamepad.buttonY))
        handledObjects.insert(ObjectIdentifier(gamepad.leftShoulder))
        handledObjects.insert(ObjectIdentifier(gamepad.rightShoulder))
        handledObjects.insert(ObjectIdentifier(gamepad.leftTrigger as GCControllerButtonInput))
        handledObjects.insert(ObjectIdentifier(gamepad.rightTrigger as GCControllerButtonInput))
        if let o = gamepad.buttonOptions { handledObjects.insert(ObjectIdentifier(o)) }
        if let m = gamepad.buttonMenu as GCControllerButtonInput? { handledObjects.insert(ObjectIdentifier(m)) }
        if let h = gamepad.buttonHome { handledObjects.insert(ObjectIdentifier(h)) }
        if let l = gamepad.leftThumbstickButton { handledObjects.insert(ObjectIdentifier(l)) }
        if let r = gamepad.rightThumbstickButton { handledObjects.insert(ObjectIdentifier(r)) }

        var result: [(GCControllerButtonInput, Int)] = []
        var nextDynamic = 20

        for (name, button) in controller.physicalInputProfile.buttons.sorted(by: { $0.key < $1.key }) {
            if handledObjects.contains(ObjectIdentifier(button)) { continue }
            if Self.ignoredProfileNames.contains(where: { name.contains($0) }) { continue }

            let btnIndex: Int
            if let known = Self.knownButtonMap[name] {
                btnIndex = known
            } else {
                let lower = name.lowercased()
                if lower.contains("touchpad") || lower.contains("pad button") {
                    btnIndex = 13
                } else if lower.contains("share") || lower.contains("create") || lower.contains("capture") {
                    btnIndex = 14
                } else if lower.contains("mute") || lower.contains("microphone") {
                    btnIndex = 15
                } else {
                    btnIndex = nextDynamic
                    nextDynamic += 1
                }
            }
            result.append((button, btnIndex))
        }

        cachedExtraButtons[index] = result
    }

    func controllerName(at index: Int) -> String {
        if index < connectedControllers.count {
            return connectedControllers[index].vendorName ?? "Controller \(index)"
        }
        return "No controller in slot \(index)"
    }

    /// Set the controller's light bar color (DualSense, DualShock 4)
    func setControllerLight(at index: Int) {
        guard index < connectedControllers.count else { return }
        // Use stored custom color if set, otherwise use slot default
        if let custom = lightColors[index] {
            applyLight(at: index, red: custom.r, green: custom.g, blue: custom.b)
        } else {
            let colorIndex = index % Self.slotColors.count
            let color = Self.slotColors[colorIndex]
            applyLight(at: index, red: color.r, green: color.g, blue: color.b)
        }
    }

    /// Set a custom light color on a controller
    func setControllerLight(at index: Int, red: Float, green: Float, blue: Float) {
        guard index < connectedControllers.count else { return }
        lightColors[index] = (r: red, g: green, b: blue)
        applyLight(at: index, red: red, green: green, blue: blue)
    }

    /// Set light brightness (0=off, 1=dim, 2=bright) by scaling the RGB values
    func setControllerBrightness(at index: Int, brightness: UInt8) {
        guard index < connectedControllers.count else { return }
        lightBrightness[index] = brightness
        if let custom = lightColors[index] {
            applyLight(at: index, red: custom.r, green: custom.g, blue: custom.b)
        } else {
            setControllerLight(at: index)
        }
    }

    /// RGB cycle mode
    @Published var rgbCycleActive: [Int: Bool] = [:]
    private var rgbHue: Float = 0

    func toggleRGBCycle(at index: Int) {
        if rgbCycleActive[index] == true {
            stopRGBCycle(at: index)
        } else {
            startRGBCycle(at: index)
        }
    }

    private func startRGBCycle(at index: Int) {
        rgbCycleActive[index] = true
        rgbHue = 0
        cycleNextColor(at: index)
    }

    private func cycleNextColor(at index: Int) {
        guard rgbCycleActive[index] == true else { return }

        let (r, g, b) = Self.hsbToRGB(h: rgbHue, s: 1.0, b: 1.0)
        lightColors[index] = (r: r, g: g, b: b)
        applyLight(at: index, red: r, green: g, blue: b)
        rgbHue += 0.08
        if rgbHue > 1.0 { rgbHue -= 1.0 }

        // Schedule next color after the helper finishes (~1.2s accounts for agent kill + restart)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.cycleNextColor(at: index)
        }
    }

    func stopRGBCycle(at index: Int) {
        rgbCycleActive[index] = false
    }

    private static func hsbToRGB(h: Float, s: Float, b: Float) -> (Float, Float, Float) {
        let c = b * s
        let x = c * (1 - abs(fmodf(h * 6, 2) - 1))
        let m = b - c
        let (r, g, bl): (Float, Float, Float)
        switch Int(h * 6) % 6 {
        case 0: (r, g, bl) = (c, x, 0)
        case 1: (r, g, bl) = (x, c, 0)
        case 2: (r, g, bl) = (0, c, x)
        case 3: (r, g, bl) = (0, x, c)
        case 4: (r, g, bl) = (x, 0, c)
        default: (r, g, bl) = (c, 0, x)
        }
        return (r + m, g + m, bl + m)
    }

    /// Apply the light color via the LightHelper subprocess, scaling by brightness
    private func applyLight(at index: Int, red: Float, green: Float, blue: Float) {
        let brightness = lightBrightness[index] ?? 2
        let scale: Float = switch brightness {
        case 0: 0.0
        case 1: 0.25
        default: 1.0
        }
        let r = UInt8(min(max(red * scale * 255, 0), 255))
        let g = UInt8(min(max(green * scale * 255, 0), 255))
        let b = UInt8(min(max(blue * scale * 255, 0), 255))
        HIDLightController.shared.setLightColor(red: r, green: g, blue: b)
    }

    // MARK: - Input Scanning

    func startScanning(completion: @escaping (InputEvent) -> Void) {
        isScanning = true
        scanCallback = completion

        // Set up value changed handlers on all connected controllers
        for (controllerIndex, controller) in connectedControllers.enumerated() {
            setupScanHandlers(for: controller, index: controllerIndex)
        }
    }

    func stopScanning() {
        isScanning = false
        scanCallback = nil
        // Remove handlers
        for controller in connectedControllers {
            removeScanHandlers(for: controller)
        }
    }

    /// Maps well-known physical profile button names to stable button indices.
    private static let knownButtonMap: [String: Int] = buildKnownButtonMap()

    private static func buildKnownButtonMap() -> [String: Int] {
        var m = [String: Int]()
        m["Button A"] = 0; m["Button B"] = 1; m["Button X"] = 2; m["Button Y"] = 3
        m["Left Shoulder"] = 4; m["Right Shoulder"] = 5
        m["Left Trigger"] = 6; m["Right Trigger"] = 7
        m["Button Options"] = 8; m["Button Menu"] = 9; m["Button Home"] = 10
        m["Left Thumbstick Button"] = 11; m["Right Thumbstick Button"] = 12
        m["Button Touchpad"] = 13; m["Touchpad Button"] = 13; m["Touchpad Primary Button"] = 13
        m["Button Share"] = 14; m["Button Capture"] = 14
        m["Create Button"] = 14; m["Share Button"] = 14
        m["Button Mute"] = 15; m["Microphone Button"] = 15; m["Mute Button"] = 15
        m["PS Button"] = 10; m["PlayStation Button"] = 10
        m["Left Paddle"] = 16; m["Right Paddle"] = 17
        m["Button Paddle 1"] = 16; m["Button Paddle 2"] = 17
        m["Button Paddle 3"] = 18; m["Button Paddle 4"] = 19
        m["Paddle 1"] = 16; m["Paddle 2"] = 17; m["Paddle 3"] = 18; m["Paddle 4"] = 19
        return m
    }

    /// Button names that are composites (D-pad, sticks), not individual buttons
    private static let ignoredProfileNames: [String] = [
        "Direction Pad", "Left Thumbstick", "Right Thumbstick"
    ]

    private func setupScanHandlers(for controller: GCController, index: Int) {
        guard let gamepad = controller.extendedGamepad else {
            setupPhysicalProfileScanHandlers(for: controller, index: index)
            return
        }

        // --- Standard extendedGamepad buttons ---
        let buttons: [(GCControllerButtonInput, Int)] = [
            (gamepad.buttonA, 0),
            (gamepad.buttonB, 1),
            (gamepad.buttonX, 2),
            (gamepad.buttonY, 3),
            (gamepad.leftShoulder, 4),
            (gamepad.rightShoulder, 5),
            (gamepad.leftTrigger, 6),
            (gamepad.rightTrigger, 7),
        ]

        var allMappedButtons: [(GCControllerButtonInput, Int)] = buttons

        if let options = gamepad.buttonOptions { allMappedButtons.append((options, 8)) }
        if let menu = gamepad.buttonMenu as GCControllerButtonInput? { allMappedButtons.append((menu, 9)) }
        if let home = gamepad.buttonHome { allMappedButtons.append((home, 10)) }
        if let l3 = gamepad.leftThumbstickButton { allMappedButtons.append((l3, 11)) }
        if let r3 = gamepad.rightThumbstickButton { allMappedButtons.append((r3, 12)) }

        for (button, btnIndex) in allMappedButtons {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        let event = InputEvent.button(btnIndex)
                        self?.lastInput = (index, event)
                        self?.scanCallback?(event)
                    }
                }
            }
        }

        // --- ALL physical profile buttons (catches touchpad, mute, share, paddles, etc.) ---
        let profileButtons = controller.physicalInputProfile.buttons
        // Track which GCControllerButtonInput objects we already handled via extendedGamepad
        let alreadyHandled = Set(allMappedButtons.map { ObjectIdentifier($0.0) })
        var usedIndices = Set(allMappedButtons.map { $0.1 })
        var nextDynamicIndex = 20 // Reserve 0-19 for known buttons

        #if DEBUG
        print("[GCS] Physical profile buttons for \(controller.vendorName ?? "?"): \(Array(profileButtons.keys).sorted())")
        #endif

        for (name, button) in profileButtons.sorted(by: { $0.key < $1.key }) {
            // Skip if already handled via extendedGamepad
            if alreadyHandled.contains(ObjectIdentifier(button)) { continue }
            // Skip composite elements
            if Self.ignoredProfileNames.contains(where: { name.contains($0) }) { continue }

            // Determine button index: use known map or assign dynamic
            let btnIndex: Int
            if let known = Self.knownButtonMap[name] {
                btnIndex = known
            } else {
                // Fuzzy match
                let lower = name.lowercased()
                if lower.contains("touchpad") || lower.contains("pad button") {
                    btnIndex = 13
                } else if lower.contains("share") || lower.contains("create") || lower.contains("capture") {
                    btnIndex = 14
                } else if lower.contains("mute") || lower.contains("microphone") {
                    btnIndex = 15
                } else if lower.contains("paddle") {
                    btnIndex = nextDynamicIndex
                    nextDynamicIndex += 1
                } else {
                    btnIndex = nextDynamicIndex
                    nextDynamicIndex += 1
                }
            }

            if usedIndices.contains(btnIndex) && btnIndex >= 20 {
                // Dynamic index collision, skip
                continue
            }
            usedIndices.insert(btnIndex)

            #if DEBUG
            print("[GCS]   Mapping physical button '\(name)' -> btn \(btnIndex)")
            #endif

            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        let event = InputEvent.button(btnIndex)
                        self?.lastInput = (index, event)
                        self?.scanCallback?(event)
                    }
                }
            }
        }

        // --- D-pad ---
        gamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                var event: InputEvent?
                if yValue > 0.5 { event = InputEvent.hat(0, direction: .up) }
                else if yValue < -0.5 { event = InputEvent.hat(0, direction: .down) }
                else if xValue < -0.5 { event = InputEvent.hat(0, direction: .left) }
                else if xValue > 0.5 { event = InputEvent.hat(0, direction: .right) }

                if let event = event {
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }

        // --- Sticks ---
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                if abs(xValue) > 0.5 {
                    let event = InputEvent.axis(0, direction: xValue > 0 ? .positive : .negative)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
                if abs(yValue) > 0.5 {
                    let event = InputEvent.axis(1, direction: yValue > 0 ? .negative : .positive)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }

        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                if abs(xValue) > 0.5 {
                    let event = InputEvent.axis(2, direction: xValue > 0 ? .positive : .negative)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
                if abs(yValue) > 0.5 {
                    let event = InputEvent.axis(3, direction: yValue > 0 ? .negative : .positive)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }

        // --- Trigger analog axes ---
        gamepad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            if value > 0.5 {
                Task { @MainActor in
                    let event = InputEvent.axis(4, direction: .positive)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }

        gamepad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            if value > 0.5 {
                Task { @MainActor in
                    let event = InputEvent.axis(5, direction: .positive)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }
    }

    private func setupPhysicalProfileScanHandlers(for controller: GCController, index: Int) {
        let profile = controller.physicalInputProfile

        for (name, button) in profile.buttons {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        // Try to extract button index from name
                        let btnIndex = self?.extractButtonIndex(from: name) ?? 0
                        let event = InputEvent.button(btnIndex)
                        self?.lastInput = (index, event)
                        self?.scanCallback?(event)
                    }
                }
            }
        }

        for (name, axis) in profile.axes {
            axis.valueChangedHandler = { [weak self] _, value in
                if abs(value) > 0.5 {
                    Task { @MainActor in
                        let axisIndex = self?.extractAxisIndex(from: name) ?? 0
                        let event = InputEvent.axis(axisIndex, direction: value > 0 ? .positive : .negative)
                        self?.lastInput = (index, event)
                        self?.scanCallback?(event)
                    }
                }
            }
        }
    }

    private func removeScanHandlers(for controller: GCController) {
        // Clear all extendedGamepad handlers
        if let gamepad = controller.extendedGamepad {
            gamepad.buttonA.pressedChangedHandler = nil
            gamepad.buttonB.pressedChangedHandler = nil
            gamepad.buttonX.pressedChangedHandler = nil
            gamepad.buttonY.pressedChangedHandler = nil
            gamepad.leftShoulder.pressedChangedHandler = nil
            gamepad.rightShoulder.pressedChangedHandler = nil
            gamepad.leftTrigger.pressedChangedHandler = nil
            gamepad.leftTrigger.valueChangedHandler = nil
            gamepad.rightTrigger.pressedChangedHandler = nil
            gamepad.rightTrigger.valueChangedHandler = nil
            gamepad.dpad.valueChangedHandler = nil
            gamepad.leftThumbstick.valueChangedHandler = nil
            gamepad.rightThumbstick.valueChangedHandler = nil
            gamepad.buttonOptions?.pressedChangedHandler = nil
            (gamepad.buttonMenu as GCControllerButtonInput?)?.pressedChangedHandler = nil
            gamepad.buttonHome?.pressedChangedHandler = nil
            gamepad.leftThumbstickButton?.pressedChangedHandler = nil
            gamepad.rightThumbstickButton?.pressedChangedHandler = nil
        }

        // Clear ALL physical profile handlers (covers every button/axis including
        // touchpad, mute, share, paddles, adaptive controller buttons, etc.)
        for (_, button) in controller.physicalInputProfile.buttons {
            button.pressedChangedHandler = nil
            button.valueChangedHandler = nil
        }
        for (_, axis) in controller.physicalInputProfile.axes {
            axis.valueChangedHandler = nil
        }
    }

    // MARK: - Polling (for mapping engine)

    func readControllerState(at index: Int) -> ControllerState? {
        guard index < connectedControllers.count else { return nil }
        let controller = connectedControllers[index]

        var state = ControllerState()

        if let gamepad = controller.extendedGamepad {
            // --- Standard extendedGamepad buttons (0-12) ---
            state.buttons[0] = gamepad.buttonA.value
            state.buttons[1] = gamepad.buttonB.value
            state.buttons[2] = gamepad.buttonX.value
            state.buttons[3] = gamepad.buttonY.value
            state.buttons[4] = gamepad.leftShoulder.value
            state.buttons[5] = gamepad.rightShoulder.value
            state.buttons[6] = gamepad.leftTrigger.value
            state.buttons[7] = gamepad.rightTrigger.value

            if let options = gamepad.buttonOptions { state.buttons[8] = options.value }
            if let menu = gamepad.buttonMenu as GCControllerButtonInput? { state.buttons[9] = menu.value }
            if let home = gamepad.buttonHome { state.buttons[10] = home.value }
            if let l3 = gamepad.leftThumbstickButton { state.buttons[11] = l3.value }
            if let r3 = gamepad.rightThumbstickButton { state.buttons[12] = r3.value }

            // --- Extra physical profile buttons (touchpad, mute, share, paddles, etc.) ---
            // Uses pre-cached mapping built on connection so no sorting or matching at 120Hz
            if let extras = cachedExtraButtons[index] {
                for (button, btnIndex) in extras {
                    state.buttons[btnIndex] = button.value
                }
            }

            // --- Axes ---
            state.axes[0] = gamepad.leftThumbstick.xAxis.value
            state.axes[1] = -gamepad.leftThumbstick.yAxis.value
            state.axes[2] = gamepad.rightThumbstick.xAxis.value
            state.axes[3] = -gamepad.rightThumbstick.yAxis.value
            state.axes[4] = gamepad.leftTrigger.value
            state.axes[5] = gamepad.rightTrigger.value

            // --- Hat (D-pad) ---
            state.hats[0] = (gamepad.dpad.xAxis.value, gamepad.dpad.yAxis.value)
        } else {
            // Physical input profile fallback for non-standard controllers
            let profile = controller.physicalInputProfile
            for (name, button) in profile.buttons {
                let idx = extractButtonIndex(from: name)
                state.buttons[idx] = button.value
            }
            for (name, axis) in profile.axes {
                let idx = extractAxisIndex(from: name)
                state.axes[idx] = axis.value
            }
        }

        return state
    }

    // MARK: - Helpers

    private func extractButtonIndex(from name: String) -> Int {
        // Try to parse "Button 0", "Button A", etc.
        let digits = name.filter { $0.isNumber }
        return Int(digits) ?? 0
    }

    private func extractAxisIndex(from name: String) -> Int {
        let digits = name.filter { $0.isNumber }
        return Int(digits) ?? 0
    }

}
