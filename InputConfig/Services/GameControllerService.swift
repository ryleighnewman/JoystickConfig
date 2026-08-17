import Foundation
import GameController
import Combine
import AppKit

/// Readable info about a connected controller.
///
/// Equatable so the 30 s details refresh can skip re-assigning the
/// @Published `controllerDetails` dict when nothing actually changed.
/// `connectedAt` is intentionally excluded from the comparison - it's
/// always slightly different per refresh and we don't want that to
/// invalidate equality and trigger a view storm.
struct ControllerInfo: Equatable {
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
    var brand: ControllerBrand = .unknown

    static func == (lhs: ControllerInfo, rhs: ControllerInfo) -> Bool {
        return lhs.name == rhs.name
            && lhs.productCategory == rhs.productCategory
            && lhs.hasExtendedGamepad == rhs.hasExtendedGamepad
            && lhs.hasLight == rhs.hasLight
            && lhs.hasBattery == rhs.hasBattery
            && lhs.batteryLevel == rhs.batteryLevel
            && lhs.batteryState == rhs.batteryState
            && lhs.buttonCount == rhs.buttonCount
            && lhs.axisCount == rhs.axisCount
            && lhs.supportsMotion == rhs.supportsMotion
            && lhs.hasTouchpad == rhs.hasTouchpad
            && lhs.hasMicroGamepad == rhs.hasMicroGamepad
            && lhs.hasAdaptiveTriggers == rhs.hasAdaptiveTriggers
            && lhs.physicalButtonNames == rhs.physicalButtonNames
            && lhs.brand == rhs.brand
    }
}

/// Represents the current state of a connected controller
struct ControllerState {
    var buttons: [Int: Float] = [:]   // button index -> value (0.0 or 1.0)
    var axes: [Int: Float] = [:]      // axis index -> value (-1.0 to 1.0)
    var hats: [Int: (x: Float, y: Float)] = [:] // hat index -> (x, y) direction
    /// Motion-sensor channels - populated when the controller exposes a
    /// non-nil `motion` property (DualSense, DualShock 4, Switch Pro,
    /// Joy-Con). nil otherwise. Channel-keyed Float so MappingEngine can
    /// treat them like axis values.
    var motion: [MotionChannel: Float] = [:]

    /// Pre-size the backing dictionaries so the per-frame population in the
    /// 120 Hz poll loop (and the 30 Hz raw-input refresh) does not repeatedly
    /// rehash as it inserts. A controller reports up to ~21 buttons and 6
    /// axes; reserving once per fresh state removes that steady-state growth
    /// churn on the main actor without changing any read logic or output.
    init() {
        buttons.reserveCapacity(24)
        axes.reserveCapacity(8)
        hats.reserveCapacity(4)
        motion.reserveCapacity(8)
    }
}

/// One observed press from a physical input profile button.
struct PhysicalPressLog: Identifiable {
    let id = UUID()
    let slot: Int
    let name: String
    let mappedIndex: Int?
    let at: Date
}

/// Diagnostic log of recent physical button presses, shown only in the
/// Settings "Live press log". Kept OUT of GameControllerService so its
/// high-frequency, per-press updates don't invalidate the root ContentView,
/// which observes the controller service.
@MainActor
final class PhysicalPressLogStore: ObservableObject {
    static let shared = PhysicalPressLogStore()
    private init() {}

    @Published var recent: [PhysicalPressLog] = []

    func log(slot: Int, name: String, mappedIndex: Int?) {
        recent.insert(PhysicalPressLog(slot: slot, name: name, mappedIndex: mappedIndex, at: Date()), at: 0)
        if recent.count > 30 {
            recent.removeLast(recent.count - 30)
        }
    }
}

/// Manages game controller detection and input reading
@MainActor
class GameControllerService: ObservableObject {
    @Published var connectedControllers: [GCController] = []
    @Published var controllerNames: [Int: String] = [:]
    @Published var controllerDetails: [Int: ControllerInfo] = [:]
    // Not @Published: no view observes these (LED state is driven to hardware
    // and the RGB/brightness UI reads rgbCycleActive/lightPresets instead), so
    // publishing fired the whole service's objectWillChange on every 10 Hz RGB
    // tick for zero UI benefit. Plain vars: identical internal reads/writes.
    var lightColors: [Int: (r: Float, g: Float, b: Float)] = [:]
    var lightBrightness: [Int: UInt8] = [:] // 0=off, 1=dim, 2=bright
    // NOTE: there used to be a `@Published var lastInput` here that every
    // scan handler wrote on every input event. Nothing read it, but each
    // write fired objectWillChange on this service at the controller's
    // report rate (250+ Hz on Bluetooth), forcing a full re-layout of every
    // observing view. Held sticks pinned the main thread at 90%+ CPU.
    @Published var isScanning: Bool = false
    /// Serialized input event strings (e.g. "btn 5", "axi 0 +") that are
    /// currently pressed / deflected across *any* connected controller.
    /// Refreshed at 10 Hz independent of the mapping engine, so the editor's
    /// binding row highlight works even when no preset is running.
    @Published var rawActiveInputs: Set<String> = []

    /// When true, the Quick Tour has injected a synthetic DualSense
    /// Edge entry into `controllerDetails[0]` so the visualizer can
    /// render all its widgets even with no real controller connected.
    /// The tour clears this on tear-down. Backing storage for the
    /// real entry (if any) is preserved.
    @Published private(set) var tutorialFakeControllerActive: Bool = false
    private var preTutorialControllerDetails: ControllerInfo?

    /// Install a synthetic DualSense Edge entry into slot 0 so the
    /// Quick Tour can light up every visualizer widget regardless of
    /// what hardware the user has plugged in. Reversible via
    /// `disableTutorialFakeController()`.
    func enableTutorialFakeController() {
        preTutorialControllerDetails = controllerDetails[0]
        let info = ControllerInfo(
            name: "DualSense Edge Wireless Controller (Tutorial)",
            productCategory: "DualSense Edge",
            hasExtendedGamepad: true,
            hasLight: true,
            hasBattery: true,
            batteryLevel: 1.0,
            batteryState: "charging",
            buttonCount: 18,
            axisCount: 6,
            supportsMotion: true,
            hasTouchpad: true,
            hasMicroGamepad: false,
            hasAdaptiveTriggers: true,
            physicalButtonNames: ["A", "B", "X", "Y", "LB", "RB",
                                  "LT", "RT", "Share", "Menu", "Home",
                                  "L3", "R3", "Touchpad", "Mute",
                                  "Left Paddle", "Right Paddle"],
            brand: .dualSense
        )
        controllerDetails[0] = info
        tutorialFakeControllerActive = true
        // Set a flag so a force-quit during the tour doesn't leave the
        // synthetic controller in place on next launch. We check this
        // in init() and immediately undo if found.
        UserDefaults.standard.set(true, forKey: Self.tutorialFakeFlagKey)
    }

    /// Remove the synthetic Quick Tour controller and restore whatever
    /// real entry was there before (or nothing).
    func disableTutorialFakeController() {
        if let real = preTutorialControllerDetails {
            controllerDetails[0] = real
        } else {
            controllerDetails.removeValue(forKey: 0)
        }
        preTutorialControllerDetails = nil
        tutorialFakeControllerActive = false
        UserDefaults.standard.removeObject(forKey: Self.tutorialFakeFlagKey)
    }

    /// UserDefaults key for the "synthetic tutorial controller is
    /// currently injected" flag. Persists across launches so a force-
    /// quit during the tour can be detected and cleaned up.
    private static let tutorialFakeFlagKey = "InputConfig.tutorialFakeActive"

    /// Called from init() to clear any lingering synthetic controller
    /// left behind by a force-quit during the previous tour session.
    /// Safe to call when no synthetic was active.
    private func clearStaleTutorialFakeIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.tutorialFakeFlagKey) else { return }
        // The synthetic only ever lives at slot 0. Anything that was
        // there is gone now anyway - real controllers re-register
        // through the connect notification.
        controllerDetails.removeValue(forKey: 0)
        UserDefaults.standard.removeObject(forKey: Self.tutorialFakeFlagKey)
        NSLog("[GameControllerService] Cleared stale tutorial fake controller from previous session")
    }

    #if DEBUG
    private(set) var marketingFakeActive = false
    /// DEBUG / marketing-capture only: inject two clean-named synthetic
    /// controllers (a DualSense Edge in slot 0, a PlayStation Access Controller
    /// in slot 1) so App Store screenshots show a populated sidebar and a
    /// fully-drawn visualizer with no hardware attached. Unlike the Quick Tour
    /// fake there is no "(Tutorial)" suffix. `refreshControllers()` is guarded
    /// to leave these in place. Driven by DebugMarketing.fakeController (which
    /// the `inputconfig.debug.fakecontroller` notification toggles); never
    /// compiled into a Release build.
    func setMarketingFakeControllers(_ on: Bool) {
        guard on != marketingFakeActive else { return }
        if !on {
            controllerDetails.removeValue(forKey: 0)
            controllerDetails.removeValue(forKey: 1)
            controllerNames.removeValue(forKey: 0)
            controllerNames.removeValue(forKey: 1)
            marketingFakeActive = false
            return
        }
        marketingFakeActive = true
        controllerNames[0] = "DualSense Edge Wireless Controller"
        controllerNames[1] = "Access Controller"
        controllerDetails[0] = ControllerInfo(
            name: "DualSense Edge Wireless Controller",
            productCategory: "DualSense Edge",
            hasExtendedGamepad: true, hasLight: true, hasBattery: true,
            batteryLevel: 1.0, batteryState: "charging",
            buttonCount: 18, axisCount: 6, supportsMotion: true,
            hasTouchpad: true, hasMicroGamepad: false, hasAdaptiveTriggers: true,
            physicalButtonNames: ["A", "B", "X", "Y", "LB", "RB", "LT", "RT",
                                  "Share", "Menu", "Home", "L3", "R3", "Touchpad",
                                  "Mute", "Left Paddle", "Right Paddle"],
            brand: .dualSense)
        controllerDetails[1] = ControllerInfo(
            name: "Access Controller",
            productCategory: "Access Controller",
            hasExtendedGamepad: true, hasLight: false, hasBattery: true,
            batteryLevel: 0.95, batteryState: "discharging",
            buttonCount: 8, axisCount: 2, supportsMotion: false,
            hasTouchpad: false, hasMicroGamepad: false, hasAdaptiveTriggers: false,
            physicalButtonNames: ["1", "2", "3", "4", "5", "6", "7", "8"],
            brand: .dualSense)
    }
    #endif

    /// Per-slot snapshot of the latest `ControllerState`. Updated at the
    /// same 30 Hz cadence as `rawActiveInputs`. Drives the live virtual
    /// controller visualizer.
    ///
    /// **Intentionally NOT `@Published`.** `ControllerState` doesn't conform
    /// to `Equatable` (the hat tuples can't auto-derive it), so this dict is
    /// reassigned every 30 Hz tick whether or not anything actually changed.
    /// Publishing it triggered every `@EnvironmentObject controllerService`
    /// observer to re-render 30x/sec, which made the editor and other busy
    /// views laggy. The visualizer reads this dictionary via `TimelineView`
    /// at its own cadence, so observation isn't necessary.
    var currentStates: [Int: ControllerState] = [:]

    /// Rolling log of every physical-profile button name that fired on each
    /// connected controller. Drives the Settings > Controllers diagnostic
    /// so the user can see whether a press registers and under what name -
    /// useful when a controller's button (e.g. DualSense Edge paddle) has
    /// a name our mapping table doesn't recognize. Capped at 30 entries.
    // The live physical-press diagnostic log lives in PhysicalPressLogStore
    // (defined just above this class), NOT here. It updates on every button
    // press, and on this @Published-heavy service that invalidated the root
    // ContentView (which observes the service) on every press. Only the
    // Settings "Live press log" observes the store now.

    /// Cached mapping of physical profile button name -> button index for each controller slot.
    /// Built once on connection, used every poll frame to avoid re-sorting/re-matching at 120Hz.
    private var cachedExtraButtons: [Int: [(GCControllerButtonInput, Int)]] = [:]

    /// Live snapshot of every "extra" button (PS, mute, paddles, FN,
    /// share, etc.) registered for a controller slot. Each entry pairs
    /// a human-readable label with the current pressed value. The
    /// visualizer renders these as chips so users can see at a glance
    /// what their controller is reporting.
    struct ExtraButton: Identifiable, Equatable {
        /// Stable identity derived from the button's logical index.
        /// Previously this was a fresh UUID per snapshot, which made
        /// every call to `extraButtonsSnapshot` return arrays that
        /// SwiftUI considered "different" - downstream views received
        /// new `extraButtons` parameters every 30 Hz poll tick and
        /// interfered with the binding row's highlight animation.
        var id: Int { index }
        let label: String
        let index: Int
        let pressed: Bool
    }

    func extraButtonsSnapshot(for slot: Int) -> [ExtraButton] {
        // Native GCController path: KVC-discovered buttons (paddles,
        // mute, share, FN) live in cachedExtraButtons.
        if let cached = cachedExtraButtons[slot] {
            var out = cached.map { (button, index) in
                ExtraButton(label: Self.labelForExtraButton(index: index, button: button),
                            index: index,
                            pressed: button.value > 0.5)
            }
            // Augment with DualSense Edge supplemental buttons (paddle/
            // FN/mute) when the slot's controller is a DualSense. We
            // read those bits via raw HID in DualSenseSupplementService
            // because Apple's GameController framework doesn't expose
            // them. The merge is keyed by index so a name from the
            // native list (if any) takes priority over our static names.
            if slot < connectedControllers.count {
                let c = connectedControllers[slot]
                let isDualSense = (c.vendorName ?? "").lowercased().contains("dualsense")
                    || c.productCategory.lowercased().contains("dualsense")
                if isDualSense {
                    let supplement = DualSenseSupplementService.shared.anySupplementalButtons()
                    let existingIndices = Set(out.map(\.index))
                    let supplementNames: [Int: String] = [
                        15: "Microphone / Mute",
                        16: "Left Paddle",
                        17: "Right Paddle",
                        20: "FN 1 (Left Function)",
                        21: "FN 2 (Right Function)",
                    ]
                    for (idx, name) in supplementNames where !existingIndices.contains(idx) {
                        let pressed = (supplement[idx] ?? 0) > 0.5
                        out.append(ExtraButton(label: name, index: idx, pressed: pressed))
                    }
                }
            }
            return out.sorted { $0.index < $1.index }
        }
        // Raw HID path: anything in state.buttons beyond the standard
        // 0-12 slots (face/shoulder/trigger/menu/stick-click) is an
        // "extra" button. Most gamepads have none; fight sticks /
        // arcade pads / custom controllers can have many.
        if let gamepad = rawHIDGamepadSlots[slot] {
            let state = gamepad.state
            let names = gamepad.profile?.physicalButtonNames ?? []
            let extraKeys = state.buttons.keys.filter { $0 > 12 }.sorted()
            return extraKeys.map { idx in
                let label = idx < names.count ? names[idx] : "Button \(idx)"
                return ExtraButton(label: label,
                                   index: idx,
                                   pressed: (state.buttons[idx] ?? 0) > 0.5)
            }
        }
        return []
    }

    /// Same idea for axes: anything past axis 5 (which is the standard
    /// RT analog) is an extra axis the visualizer should surface.
    /// Returns (index, label, value) tuples sorted by index. Currently
    /// only relevant for raw HID gamepads since GameController
    /// framework only exposes 6 axes.
    struct ExtraAxis: Identifiable, Equatable {
        /// Same stable-id rationale as ExtraButton above - avoids
        /// re-rendering downstream views on every snapshot tick.
        var id: Int { index }
        let label: String
        let index: Int
        let value: Float
    }

    func extraAxesSnapshot(for slot: Int) -> [ExtraAxis] {
        if let gamepad = rawHIDGamepadSlots[slot] {
            let state = gamepad.state
            let extraKeys = state.axes.keys.filter { $0 > 5 }.sorted()
            return extraKeys.map { idx in
                ExtraAxis(label: "Axis \(idx)", index: idx,
                          value: state.axes[idx] ?? 0)
            }
        }
        return []
    }

    /// Friendly name to show on each extra-button chip. Prefers the
    /// runtime's localizedName, falls back to a static map by index.
    private static func labelForExtraButton(index: Int, button: GCControllerButtonInput) -> String {
        if let localized = button.localizedName, !localized.isEmpty {
            return localized
        }
        switch index {
        case 13: return "Touchpad"
        case 14: return "Share"
        case 15: return "Microphone"
        case 16: return "Left Paddle"
        case 17: return "Right Paddle"
        case 18: return "Paddle 3"
        case 19: return "Paddle 4"
        case 20: return "FN1"
        case 21: return "FN2"
        default: return "Button \(index)"
        }
    }

    /// Slot index assigned to a connected Steam Controller. nil when no
    /// Steam Controller is currently reporting input. Always sits just past
    /// the last real MFi controller so presets keep their numbering.
    @Published var steamControllerSlot: Int?

    /// Slot indices assigned to raw HID gamepads (8BitDo Ultimate 2C in
    /// XInput mode, Xbox 360 wired, Logitech F310/F710, generic XInput
    /// pads, DualShock 3 over USB, etc.). Each entry maps a controller
    /// slot index → `RawHIDGamepad`. Slots are allocated after Steam.
    /// See `syncRawHIDGamepadSlots()`.
    @Published var rawHIDGamepadSlots: [Int: RawHIDGamepad] = [:]

    private var pollTimer: Timer?
    private var detailsTimer: Timer?
    private var steamWatchTimer: Timer?
    private var rawHIDWatchTimer: Timer?
    private var rawActivePollTimer: Timer?
    private var scanCallback: ((InputEvent) -> Void)?
    private var cancellables = Set<AnyCancellable>()
    /// Held for the app's lifetime to keep App Nap from throttling the light
    /// re-assert timers while the app is in the background.
    private var appActivityToken: NSObjectProtocol?

    init() {
        // Apple normally suppresses the Home / PS button event when an app
        // isn't actively claiming the controller. Setting this flag lets us
        // receive Home and other "background" events regardless of whether
        // the window has key focus.
        GCController.shouldMonitorBackgroundEvents = true

        // Keep the light-assertion timers (solid hold + RGB cycle) running at
        // full rate when we are not the foreground app. Without this, App Nap
        // throttles background timers, so on an app switch the system's default
        // controller LED color flashes through before we re-assert ours.
        appActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep the controller light color asserted")

        setupControllerNotifications()
        refreshControllers()
        startDetailsPolling()
        // Spin up the Steam Controller helper at launch so the device is
        // detected immediately on plug-in. The helper does nothing until a
        // physical Steam Controller appears, then disables lizard mode and
        // starts streaming raw input reports. Re-running detection at 2 Hz
        // updates the virtual slot's ControllerInfo as the helper connects.
        SteamControllerService.shared.retain()
        startSteamControllerWatch()
        startRawActiveInputsPolling()

        // Boot the raw HID gamepad layer. Covers controllers that
        // Apple's GameController framework doesn't see (8BitDo Ultimate
        // 2C in XInput mode, Xbox 360 wired pads, Logitech F310/F710,
        // DualShock 3, generic XInput controllers).
        RawHIDGamepadService.shared.start()
        startRawHIDGamepadWatch()

        // DualSense / DualSense Edge supplement. Apple's framework
        // surfaces the standard DualSense buttons but NOT the Edge's
        // exclusive ones (left/right paddle, FN1/FN2, mute). We open
        // the device a second time in non-seize mode and parse those
        // bits out of the raw report, then merge them into the
        // matching slot's ControllerState below.
        DualSenseSupplementService.shared.start()

        // MIDI input. Opens one CoreMIDI client and connects to every
        // source, so a MIDI keyboard / pad controller is bindable the
        // same way a gamepad is. Started here rather than lazily so the
        // binding editor can list devices and Scan can capture a key
        // press without the user first activating a MIDI preset.
        MIDIInputService.shared.start()

        // Open the in-process LED writer up front so focus-change
        // re-asserts and the RGB cycle can write instantly, without
        // spawning the helper subprocess. It's re-enumerated on each
        // controller connect/disconnect via refreshControllers().
        InProcessLightWriter.shared.open()

        // If a previous run force-quit during the Quick Tour, the
        // synthetic DualSense Edge entry could still be sitting at
        // slot 0 in memory we just initialized. Clean it up before
        // any UI binds to controllerDetails.
        clearStaleTutorialFakeIfNeeded()
    }

    deinit {
        // GameController + connect/disconnect observers are registered
        // against the singleton's lifetime. The service almost always
        // outlives the app process, but adding a clean teardown makes
        // the type safe to recreate in tests and stops the leak
        // analyzer flagging it. Timer cleanup is deliberately omitted:
        // Swift 6 strict-concurrency forbids touching @MainActor /
        // non-Sendable state from a nonisolated deinit, and Timer
        // properties on a main-actor class fall into that category.
        // The Timers retain self, so deinit only ever runs once the
        // run loop has already dropped them - explicit invalidate
        // would be a no-op at that point anyway.
        NotificationCenter.default.removeObserver(self)
    }

    /// Periodically refresh battery level and other dynamic details.
    /// Only re-publishes a slot's `ControllerInfo` when it actually
    /// changed - the equality check excludes the `connectedAt`
    /// timestamp so an unchanged battery reading doesn't kick every
    /// observer into a re-render every 30 seconds.
    private func startDetailsPolling() {
        detailsTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                for (index, controller) in self.connectedControllers.enumerated() {
                    let next = self.buildControllerInfo(controller)
                    if self.controllerDetails[index] != next {
                        self.controllerDetails[index] = next
                    }
                }
            }
        }
    }

    // MARK: - Controller Discovery

    private func setupControllerNotifications() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil, queue: .main
        ) { [weak self] note in
            // Extract Sendable values before crossing the actor boundary so
            // Swift 6's strict concurrency doesn't flag the Notification.
            let name = (note.object as? GCController)?.vendorName ?? "Controller"
            Task { @MainActor in
                StatsService.shared.controllerConnected(name: name)
                self?.refreshControllers()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil, queue: .main
        ) { [weak self] note in
            let name = (note.object as? GCController)?.vendorName ?? "Controller"
            Task { @MainActor in
                guard let self = self else { return }
                let stillConnected = !GCController.controllers().isEmpty
                StatsService.shared.controllerDisconnected(
                    name: name, anyStillConnected: stillConnected)
                self.refreshControllers()
            }
        }

        // gamecontrolleragentd repaints the DualSense LED to the player
        // color on EVERY system focus change - not just when our own app's
        // active state flips. The app-level didResignActive/didBecomeActive
        // only fire on our own transitions, so once we're backgrounded,
        // switching between two OTHER apps let the daemon repaint and our
        // color never came back until our app was reactivated (exactly the
        // "switching windows again reverts it" behavior).
        //
        // NSWorkspace.didActivateApplicationNotification is posted to every
        // running app whenever ANY app becomes active, so a backgrounded
        // InputConfig still receives it. We re-assert on each activation
        // (including our own), which covers every case the app-local
        // notifications missed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleFocusChange() }
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

    /// Static snapshot of currently connected controllers. Used by the test
    /// bench so injectors can grab the first available controller without
    /// needing a reference to the service singleton.
    static func snapshotControllers() -> [GCController] {
        return GCController.controllers()
    }

    func refreshControllers() {
        #if DEBUG
        // Marketing capture: leave the synthetic controllers in place rather
        // than rebuilding the (empty) slot dict from real hardware.
        if marketingFakeActive { return }
        #endif
        // Capture light/RGB state by controller identity BEFORE we
        // rebuild the slot dict. After the rebuild we reassign by
        // identity rather than blind slot index - otherwise when a
        // low-numbered controller disconnects, every higher controller
        // shifts left and a custom color set for slot 1 silently
        // transfers to whatever controller now occupies slot 1.
        var lightByIdentity: [ObjectIdentifier: (r: Float, g: Float, b: Float)] = [:]
        var brightnessByIdentity: [ObjectIdentifier: UInt8] = [:]
        var rgbActiveByIdentity: Set<ObjectIdentifier> = []
        for (slot, c) in connectedControllers.enumerated() {
            let key = ObjectIdentifier(c)
            if let color = lightColors[slot] { lightByIdentity[key] = color }
            if let bri = lightBrightness[slot] { brightnessByIdentity[key] = bri }
            if rgbCycleActive[slot] == true { rgbActiveByIdentity.insert(key) }
        }

        connectedControllers = GCController.controllers()
        controllerNames.removeAll()
        controllerDetails.removeAll()
        cachedExtraButtons.removeAll()
        dualSenseSlots.removeAll()
        // Drop press-logger bookkeeping for controllers that are gone, so the
        // wired set cannot grow across plug / unplug cycles.
        let liveControllerIDs = Set(connectedControllers.map(ObjectIdentifier.init))
        pressLoggerWired.formIntersection(liveControllerIDs)
        lightColors.removeAll()
        lightBrightness.removeAll()
        rgbCycleActive.removeAll()
        for (index, controller) in connectedControllers.enumerated() {
            // Restore per-controller-identity light state into the new slot.
            let key = ObjectIdentifier(controller)
            if let color = lightByIdentity[key] { lightColors[index] = color }
            if let bri = brightnessByIdentity[key] { lightBrightness[index] = bri }
            if rgbActiveByIdentity.contains(key) { rgbCycleActive[index] = true }
            cacheExtraButtons(for: controller, at: index)
            installPhysicalPressLogger(for: controller, slot: index)
            activateMotionSensors(for: controller)
            installTouchpadHandlers(for: controller, slot: index)
            installLiveInputHandler(for: controller)
            controllerNames[index] = controller.vendorName ?? "Controller \(index)"
            controllerDetails[index] = buildControllerInfo(controller)

            // Clear the player index up front so macOS doesn't assign a
            // player-number LED color it would later repaint over ours on
            // focus changes. See handleFocusChange() for the full rationale.
            controller.playerIndex = .indexUnset

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
        // Re-base the Steam and raw-HID virtual slots onto the new MFi slot
        // count and re-publish their metadata on this same main-actor turn.
        // refreshControllers just wiped controllerNames/controllerDetails and
        // only repopulated the MFi slots, and the base index (derived from
        // connectedControllers.count) has just shifted, so without this the
        // virtual slots would overlap or lose their metadata until the next
        // 0.5s sync tick.
        syncSteamControllerSlot()
        syncRawHIDGamepadSlots()
        // Re-enumerate the in-process LED writer so it picks up the new
        // controller set (handles hot-plug/unplug).
        InProcessLightWriter.shared.open()
        // With no controller left, stop hammering the LED so we don't spin the
        // re-assert timer for nothing.
        if connectedControllers.isEmpty { InProcessLightWriter.shared.stopHold() }

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
            physicalButtonNames: buttonNames,
            brand: ControllerTypeDetector.detect(controller)
        )
    }

    /// Ask the controller's `GCMotion` to start reporting gyro and
    /// accelerometer data. Some controllers (Switch Pro, Joy-Con, and some
    /// Bluetooth-paired DualSense / DualShock 4) require explicit activation
    /// before `motion.rotationRate` / `motion.userAcceleration` return
    /// anything other than zero. Apple exposes this via
    /// `sensorsRequireManualActivation` + `sensorsActive`; setting
    /// `sensorsActive = true` is a no-op for controllers that don't require
    /// it, so we always set it.
    private func activateMotionSensors(for controller: GCController) {
        guard let motion = controller.motion else { return }
        // Force activation regardless of `sensorsRequireManualActivation`:
        // it's safe on controllers that auto-activate and required on the
        // ones that don't.
        motion.sensorsActive = true
        #if DEBUG
        print("[GCS] Motion activated for \(controller.vendorName ?? "?")"
              + " manual=\(motion.sensorsRequireManualActivation)"
              + " active=\(motion.sensorsActive)"
              + " hasRotation=\(motion.hasRotationRate)"
              + " hasAttitude=\(motion.hasAttitude)"
              + " hasGravity=\(motion.hasGravityAndUserAcceleration)")
        #endif
    }

    /// Pre-compute the mapping of extra physical profile buttons for a controller.
    /// This runs once on connection so readControllerState doesn't rebuild it every frame.
    private func cacheExtraButtons(for controller: GCController, at index: Int) {
        // Cache the DualSense check here, once per connection. It is a
        // connection-lifetime constant, and recomputing it per poll frame
        // cost two String.lowercased() allocations per slot.
        let nameBlob = ((controller.vendorName ?? "") + " " + controller.productCategory).lowercased()
        if nameBlob.contains("dualsense") {
            dualSenseSlots.insert(index)
        }
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

        // Apple's GameController framework exposes the DualSense touchpad
        // click and microphone button on a specific subclass, not through
        // the standard physical profile, so cast and pull them explicitly.
        // This ensures the touchpad always maps to index 13 (and mic to 15)
        // regardless of how the physical profile names them.
        if let dualSense = gamepad as? GCDualSenseGamepad {
            result.append((dualSense.touchpadButton, 13))
            handledObjects.insert(ObjectIdentifier(dualSense.touchpadButton))
        }
        if let dualShock = gamepad as? GCDualShockGamepad,
           let touchpad = dualShock.touchpadButton {
            result.append((touchpad, 13))
            handledObjects.insert(ObjectIdentifier(touchpad))
        }

        // KVC-based discovery for buttons that Apple's typed classes
        // expose but aren't in every SDK: microphoneButton (DualSense
        // mute), and the Edge-specific paddle / function buttons. We
        // ask the runtime whether the property is there - if so, pull
        // the button via `value(forKey:)` and register it with a stable
        // index. This makes the Edge's hardware buttons reachable
        // without depending on a build-time `GCDualSenseEdgeGamepad`
        // symbol that this SDK may not contain.
        let kvcSpecial: [(String, Int)] = [
            ("microphoneButton",      15),
            ("leftPaddleButton",      16),
            ("rightPaddleButton",     17),
            ("leftFunctionButton",    20),
            ("rightFunctionButton",   21)
        ]
        let ns = gamepad as NSObject
        for (key, btnIndex) in kvcSpecial {
            guard ns.responds(to: NSSelectorFromString(key)) else { continue }
            guard let button = ns.value(forKey: key) as? GCControllerButtonInput else { continue }
            // Skip if we somehow already registered this exact button.
            if handledObjects.contains(ObjectIdentifier(button)) { continue }
            result.append((button, btnIndex))
            handledObjects.insert(ObjectIdentifier(button))
            #if DEBUG
            print("[GCS] KVC discovered \(key) -> btn \(btnIndex) on \(controller.vendorName ?? "?")")
            #endif
        }

        // Diagnostic: log every button name the profile reports the
        // moment we cache. NSLog (not print) so it reaches the unified
        // log immediately and survives across-process redirects - lets
        // the user see via `log stream` in Terminal exactly which
        // names Apple's framework is sending. If the PS / mute /
        // paddle / FN buttons don't appear here AND none were found
        // via KVC above, Apple's framework isn't sending them and we
        // can't map them through standard MFi APIs.
        let profileButtonNames = Array(controller.physicalInputProfile.buttons.keys).sorted()
        NSLog("[GCS] Profile button names for %@ (slot %d): %@",
              controller.vendorName ?? "?",
              index,
              profileButtonNames.joined(separator: ", "))
        NSLog("[GCS] cacheExtraButtons -> %d entries: %@",
              result.count,
              result.map { "\($0.1)" }.joined(separator: ", "))

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
        // Steam Controller virtual slot just past the real MFi ones.
        if let steamSlot = steamControllerSlot, index == steamSlot {
            return "Steam Controller"
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

    /// Last RGB (already brightness-scaled, 0-255) written per slot. macOS
    /// repaints the DualSense light to its default on focus changes, so we
    /// re-assert this on every system app activation (see the NSWorkspace
    /// observer in init) to keep the user's / preset's color showing.
    private var lastAppliedColor: [Int: (r: UInt8, g: UInt8, b: UInt8)] = [:]

    /// Last color the RGB rainbow wrote (brightness-scaled, 0-255). When a
    /// focus change interrupts the cycle we snap straight back to THIS color
    /// so the rainbow stays visually continuous across an app switch instead
    /// of flashing the system default.
    private var lastRGBColor: (r: UInt8, g: UInt8, b: UInt8)?

    /// Re-assert the current color via the in-process writer - instant, no
    /// subprocess spawn, no daemon kill - so an app switch snaps back to our
    /// color as fast as possible. During the RGB cycle we re-send the exact
    /// last rainbow color; otherwise each slot's last applied color.
    func reassertLights() {
        if rgbCycleActive.values.contains(true) {
            if let c = lastRGBColor {
                InProcessLightWriter.shared.write(red: c.r, green: c.g, blue: c.b)
            }
            return
        }
        for (_, c) in lastAppliedColor {
            InProcessLightWriter.shared.write(red: c.r, green: c.g, blue: c.b)
        }
    }

    /// Defense against the focus-change LED repaint. gamecontrolleragentd
    /// repaints the LED on every system focus change; we (1) clear the
    /// player index so it has no player color to repaint TO, and (2)
    /// re-assert our color via the in-process writer on a tight burst of
    /// delays so our write wins the instant the daemon repaints. In-process
    /// writes are essentially free, so we fire several inside the first
    /// ~400 ms to make the correction as fast and smooth as possible.
    private func handleFocusChange() {
        clearPlayerIndices()
        reassertLights()
        for delay in [0.02, 0.05, 0.1, 0.2, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.clearPlayerIndices()
                self?.reassertLights()
            }
        }
    }

    /// Set every connected controller's player index to "unset" so macOS
    /// shows no player-number LED color. Cheap and idempotent; safe to
    /// call repeatedly. Nothing else in the app keys off `playerIndex`
    /// (slot numbering is by array index), so clearing it has no side
    /// effects beyond suppressing the system LED color.
    private func clearPlayerIndices() {
        for c in connectedControllers {
            c.playerIndex = .indexUnset
        }
    }

    /// RGB cycle mode
    @Published var rgbCycleActive: [Int: Bool] = [:]
    private var rgbHue: Float = 0
    /// Drives the live RGB rainbow. A single shared timer services every
    /// slot with the cycle enabled (the LED write targets all Sony
    /// controllers, matching the rest of the light path).
    private var rgbTimer: Timer?
    /// Base loop length and LED update rate. 40 Hz makes the rainbow
    /// seamless; the user-facing speed slider scales the per-tick hue
    /// advance via `rgbCycleSpeed`.
    private let rgbFullLoopSeconds: Double = 3.0
    private let rgbUpdateHz: Double = 40.0
    /// User-adjustable cycle speed (the slider in every RGB menu). 1.0 = one
    /// full rainbow every `rgbFullLoopSeconds`; higher = faster. Persisted so
    /// the choice sticks across launches.
    @Published var rgbCycleSpeed: Double =
        (UserDefaults.standard.object(forKey: "InputConfig.rgbCycleSpeed") as? Double) ?? 1.0 {
        didSet { UserDefaults.standard.set(rgbCycleSpeed, forKey: "InputConfig.rgbCycleSpeed") }
    }
    /// Throttle so we publish to `lightColors` (the UI swatch) at ~10 Hz
    /// instead of the full LED rate, avoiding a 40 Hz SwiftUI re-render storm.
    private var rgbTickCount: Int = 0

    func toggleRGBCycle(at index: Int) {
        if rgbCycleActive[index] == true {
            stopRGBCycle(at: index)
        } else {
            startRGBCycle(at: index)
        }
    }

    private func startRGBCycle(at index: Int) {
        rgbCycleActive[index] = true
        // The cycle feeds its color into the same background hammer as solid
        // colors (via rgbTick -> startHold), so it survives app-switch throttling.
        // Re-enumerate + open the controller(s) for fast, subprocess-free
        // writes (kept open afterwards for the focus-change re-assert).
        InProcessLightWriter.shared.open()
        guard rgbTimer == nil else { return }   // shared timer already running
        // Do NOT reset rgbHue here: keep the rainbow's current position so the
        // cycle resumes where it left off rather than snapping back to red when
        // it restarts (e.g. after setting a color or a menu round-trip).
        rgbTickCount = 0
        let timer = Timer(timeInterval: 1.0 / rgbUpdateHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rgbTick() }
        }
        rgbTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One frame of the rainbow: advance the hue (scaled by the speed
    /// slider), write it straight to the LED via the in-process writer, and
    /// (throttled) update the UI swatch.
    private func rgbTick() {
        // Stop once no slot wants the cycle anymore. We leave the in-process
        // writer open so the focus-change re-assert stays instant.
        guard rgbCycleActive.values.contains(true) else {
            rgbTimer?.invalidate(); rgbTimer = nil
            return
        }

        let (r, g, b) = Self.hsbToRGB(h: rgbHue, s: 1.0, b: 1.0)
        // Honor the brightness of the first active slot the same way
        // applyLight() does - pre-scale the RGB; the report's brightness
        // byte stays at its default.
        let bri = rgbCycleActive.first(where: { $0.value })
            .flatMap { lightBrightness[$0.key] } ?? 2
        let scale: Float = switch bri { case 0: 0.0; case 1: 0.25; default: 1.0 }
        let r8 = UInt8(min(max(r * scale * 255, 0), 255))
        let g8 = UInt8(min(max(g * scale * 255, 0), 255))
        let b8 = UInt8(min(max(b * scale * 255, 0), 255))
        // Feed the rainbow frame into the background hammer (200 Hz) instead of
        // writing once from this main-thread timer, which the OS throttles on
        // app switch (causing the LED to flash to the system default mid-cycle).
        InProcessLightWriter.shared.startHold(red: r8, green: g8, blue: b8)
        lastRGBColor = (r8, g8, b8)   // snap-back target for app switches

        // Publish to the UI swatch at ~10 Hz, not the full 40 Hz LED rate.
        rgbTickCount += 1
        if rgbTickCount % 4 == 0 {
            for (slot, on) in rgbCycleActive where on { lightColors[slot] = (r, g, b) }
        }

        // Hue advance per tick scaled by the speed slider (clamped so the
        // cycle can't stall or run away).
        let speed = min(max(rgbCycleSpeed, 0.1), 8.0)
        rgbHue += Float(speed / (rgbFullLoopSeconds * rgbUpdateHz))
        if rgbHue > 1.0 { rgbHue -= 1.0 }
    }

    func stopRGBCycle(at index: Int) {
        rgbCycleActive[index] = false
        // Tear down the shared timer only when no slot is still cycling.
        guard !rgbCycleActive.values.contains(true) else { return }
        rgbTimer?.invalidate(); rgbTimer = nil
        lastRGBColor = nil
        // Freeze on the current color and route it through the normal path
        // so the focus-change re-assert keeps showing it.
        setControllerLight(at: index)
    }

    /// Stop the rainbow on every slot at once. Called when a preset with a
    /// light-bar color activates so the preset's color overrides the cycle
    /// instead of being overwritten by the next rainbow frame.
    func stopAllRGBCycles() {
        guard rgbCycleActive.values.contains(true) else { return }
        for key in rgbCycleActive.keys { rgbCycleActive[key] = false }
        rgbTimer?.invalidate(); rgbTimer = nil
        lastRGBColor = nil
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

    /// Apply a light color WITHOUT storing it as the slot's default. Used by
    /// the mapping engine to flash a preset's chosen color while the preset
    /// is active; calling `setControllerLight(at:)` on stop restores the
    /// stored (user-default) color. Pass `brightness` to override the
    /// stored brightness for the duration; nil inherits.
    func applyTemporaryLight(at index: Int, red: Float, green: Float, blue: Float, brightness: UInt8? = nil) {
        guard index < connectedControllers.count else { return }
        let bri = brightness ?? lightBrightness[index] ?? 2
        let scale: Float = switch bri {
        case 0: 0.0
        case 1: 0.25
        default: 1.0
        }
        let r = UInt8(min(max(red * scale * 255, 0), 255))
        let g = UInt8(min(max(green * scale * 255, 0), 255))
        let b = UInt8(min(max(blue * scale * 255, 0), 255))
        lastAppliedColor[index] = (r, g, b)
        // HOLD the color, don't fire one shot. macOS's controller daemon owns
        // the DualSense light bar and repaints it on its own loop, so a single
        // write is overwritten within milliseconds and the user sees nothing
        // change when a preset with a light-bar override activates. The general
        // light path (applyLight) already holds for exactly this reason; the
        // per-preset override was the one path still doing a bare write.
        // stopHold happens on revert via setControllerLight, and when the last
        // controller disconnects.
        InProcessLightWriter.shared.startHold(red: r, green: g, blue: b)
    }

    /// Apply the light color in-process via the shared LED writer, scaling by
    /// brightness. (Previously spawned the LightHelper subprocess, which crashes
    /// with SIGTRAP under the sandbox + hardened runtime when the app launches
    /// it, so the LED never updated.)
    private func applyLight(at index: Int, red: Float, green: Float, blue: Float) {
        guard index < connectedControllers.count else { return }
        let brightness = lightBrightness[index] ?? 2
        let scale: Float = switch brightness {
        case 0: 0.0
        case 1: 0.25
        default: 1.0
        }
        let r = UInt8(min(max(red * scale * 255, 0), 255))
        let g = UInt8(min(max(green * scale * 255, 0), 255))
        let b = UInt8(min(max(blue * scale * 255, 0), 255))
        connectedControllers[index].playerIndex = .indexUnset
        lastAppliedColor[index] = (r, g, b)
        // Hand the color to the high-rate hold writer, which hammers it onto the
        // LED from its own background queue. macOS 26's gamecontrollerd repaints
        // the LED on focus changes and on a loop while we're foreground, so a
        // single write loses (the color only appeared after clicking away, when
        // the daemon let go). Hammering overwrites the daemon within a few ms.
        InProcessLightWriter.shared.startHold(red: r, green: g, blue: b)
    }

    // MARK: - Input Scanning

    func startScanning(completion: @escaping (InputEvent) -> Void) {
        isScanning = true
        scanCallback = completion

        // Set up value changed handlers on all connected controllers
        for (controllerIndex, controller) in connectedControllers.enumerated() {
            setupScanHandlers(for: controller, index: controllerIndex)
        }

        // Watch for motion deflection too - tilting the controller past
        // a threshold during scan fires InputEvent.motion so the user
        // can assign gyro tilts to outputs from the same Scan flow.
        motionScanTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMotionForScan() }
        }
        motionScanTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        // MIDI devices join the same Scan flow: press a key, twist a
        // knob, or move the bend wheel and it is captured like any
        // button. Opens the input port on demand so users who never
        // touch MIDI never pay for a CoreMIDI client.
        MIDIInputService.shared.startScanning { [weak self] event in
            Task { @MainActor in self?.scanCallback?(event) }
        }
    }

    func stopScanning() {
        isScanning = false
        scanCallback = nil
        MIDIInputService.shared.stopScanning()
        motionScanTimer?.invalidate()
        motionScanTimer = nil
        motionScanFiredThisGesture = false
        // Remove the scan handlers, then immediately re-assert the live-input
        // handler so the poll keeps reading values after the editor closes.
        for controller in connectedControllers {
            removeScanHandlers(for: controller)
            installLiveInputHandler(for: controller)
        }
    }

    /// Timer that polls every connected controller's gyro rate during
    /// scan. Single-shot per gesture (latched in
    /// `motionScanFiredThisGesture`) so a sustained tilt doesn't spam
    /// the scan callback.
    private var motionScanTimer: Timer?
    private var motionScanFiredThisGesture: Bool = false
    /// rad/s threshold. ~1.5 is roughly a brisk tilt; lower triggers on
    /// noise, higher requires the user to whip the controller.
    private let motionScanThreshold: Float = 1.5

    private func checkMotionForScan() {
        guard isScanning, let cb = scanCallback else { return }

        // Find max-magnitude axis across all connected motion controllers.
        // Whichever axis crosses threshold first wins the scan.
        for controller in connectedControllers {
            guard let motion = controller.motion, motion.hasRotationRate else { continue }
            let key = MotionCalibrationService.identityKey(for: controller)
            let (gx, gy, gz) = MotionCalibrationService.shared.correctedGyro(
                x: Float(motion.rotationRate.x),
                y: Float(motion.rotationRate.y),
                z: Float(motion.rotationRate.z),
                forKey: key)

            let mag = max(abs(gx), abs(gy), abs(gz))
            // Latch: only fire once per gesture. Reset when rates drop
            // back below 25% of threshold so the user can re-tilt for a
            // second scan.
            if motionScanFiredThisGesture {
                if mag < motionScanThreshold * 0.25 {
                    motionScanFiredThisGesture = false
                }
                continue
            }
            guard mag >= motionScanThreshold else { continue }

            let event: InputEvent
            if abs(gx) >= abs(gy) && abs(gx) >= abs(gz) {
                event = .motion(.gyroX, direction: gx > 0 ? .positive : .negative)
            } else if abs(gy) >= abs(gz) {
                event = .motion(.gyroY, direction: gy > 0 ? .positive : .negative)
            } else {
                event = .motion(.gyroZ, direction: gz > 0 ? .positive : .negative)
            }
            motionScanFiredThisGesture = true
            cb(event)
            return
        }
    }

    /// Maps well-known physical profile button names to stable button indices.
    private static let knownButtonMap: [String: Int] = buildKnownButtonMap()

    /// Public mirror of `knownButtonMap` so views (e.g. Settings' controller
    /// diagnostic) can show which name maps to which button index.
    static let publicKnownButtonMap: [String: Int] = buildKnownButtonMap()

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
        m["Left Paddle Button"] = 16; m["Right Paddle Button"] = 17
        m["Button Paddle 1"] = 16; m["Button Paddle 2"] = 17
        m["Button Paddle 3"] = 18; m["Button Paddle 4"] = 19
        m["Paddle 1"] = 16; m["Paddle 2"] = 17; m["Paddle 3"] = 18; m["Paddle 4"] = 19
        // DualSense Edge function buttons (the two small buttons just below
        // each analog stick).
        m["Left Function Button"] = 20; m["Right Function Button"] = 21
        m["FN1 Button"] = 20; m["FN2 Button"] = 21
        m["FN1"] = 20; m["FN2"] = 21
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

        // Diagnostic: log which typed buttons we successfully wired up.
        // If buttonHome is missing from this list, gamepad.buttonHome
        // returned nil on this controller and the PS press won't fire
        // our typed handler at all - we'd have to fall through to the
        // physical-profile scan handler instead.
        NSLog("[GCS] setupScanHandlers wired %d typed buttons on slot %d (controller=%@, hasHome=%@, hasOptions=%@, hasMenu=%@)",
              allMappedButtons.count, index,
              controller.vendorName ?? "?",
              gamepad.buttonHome != nil ? "YES" : "no",
              gamepad.buttonOptions != nil ? "YES" : "no",
              gamepad.buttonMenu as GCControllerButtonInput? != nil ? "YES" : "no")

        for (button, btnIndex) in allMappedButtons {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        // Loud diagnostic so we can see if the typed-handler
                        // path is actually firing for PS / Home / Mute /
                        // paddle presses. Visible via `log stream` in
                        // Terminal so the user can confirm presses reach us.
                        NSLog("[GCS] SCAN typed btn fired: slot=%d index=%d", index, btnIndex)
                        let event = InputEvent.button(btnIndex)
                        self?.scanCallback?(event)
                    }
                }
            }
        }

        // --- Extra physical profile buttons (touchpad click, share, mute,
        //     paddles, DualSense Edge FN buttons, etc.) ---
        // Use the EXACT same mapping that `readControllerState` will use to
        // read state every frame. Previously the scan path and the read
        // path each built their own dynamic-index mapping; if they
        // disagreed for any unknown name (very common on DualSense Edge),
        // scanning would record one button index and the engine would
        // never see it pressed under that index again.
        let alreadyHandled = Set(allMappedButtons.map { ObjectIdentifier($0.0) })
        let cached = cachedExtraButtons[index] ?? []
        for (button, btnIndex) in cached where !alreadyHandled.contains(ObjectIdentifier(button)) {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        let event = InputEvent.button(btnIndex)
                        self?.scanCallback?(event)
                    }
                }
            }
        }

        #if DEBUG
        let names = Array(controller.physicalInputProfile.buttons.keys).sorted()
        print("[GCS] Physical profile buttons for \(controller.vendorName ?? "?"): \(names)")
        print("[GCS] Cached extras (button -> index):")
        for (_, btnIndex) in cached {
            print("[GCS]   -> btn \(btnIndex)")
        }
        #endif

        // --- D-pad ---
        gamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                var event: InputEvent?
                if yValue > 0.5 { event = InputEvent.hat(0, direction: .up) }
                else if yValue < -0.5 { event = InputEvent.hat(0, direction: .down) }
                else if xValue < -0.5 { event = InputEvent.hat(0, direction: .left) }
                else if xValue > 0.5 { event = InputEvent.hat(0, direction: .right) }

                if let event = event {
                    self?.scanCallback?(event)
                }
            }
        }

        // --- Sticks ---
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                if abs(xValue) > 0.5 {
                    let event = InputEvent.axis(0, direction: xValue > 0 ? .positive : .negative)
                    self?.scanCallback?(event)
                }
                if abs(yValue) > 0.5 {
                    let event = InputEvent.axis(1, direction: yValue > 0 ? .negative : .positive)
                    self?.scanCallback?(event)
                }
            }
        }

        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                if abs(xValue) > 0.5 {
                    let event = InputEvent.axis(2, direction: xValue > 0 ? .positive : .negative)
                    self?.scanCallback?(event)
                }
                if abs(yValue) > 0.5 {
                    let event = InputEvent.axis(3, direction: yValue > 0 ? .negative : .positive)
                    self?.scanCallback?(event)
                }
            }
        }

        // --- Trigger analog axes ---
        gamepad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            if value > 0.5 {
                Task { @MainActor in
                    let event = InputEvent.axis(4, direction: .positive)
                    self?.scanCallback?(event)
                }
            }
        }

        gamepad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            if value > 0.5 {
                Task { @MainActor in
                    let event = InputEvent.axis(5, direction: .positive)
                    self?.scanCallback?(event)
                }
            }
        }
    }

    private func setupPhysicalProfileScanHandlers(for controller: GCController, index: Int) {
        let profile = controller.physicalInputProfile

        for (name, button) in profile.buttons {
            // Capture the button's ObjectIdentifier outside the Task -
            // it's a Sendable value (just a pointer wrapper) where the
            // class reference itself is not Sendable and can't cross
            // the @MainActor boundary under strict concurrency.
            let buttonID = ObjectIdentifier(button)
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        guard let self = self else { return }
                        // Resolve the right index for this button.
                        //
                        // 1) Prefer the cached extras lookup - it was built
                        //    on connect via KVC, so it has the correct
                        //    index for DualSense Edge paddles ("Left Paddle"
                        //    → 16, "Right Paddle" → 17, "Mute"/microphone →
                        //    15, FN buttons → 20/21) and for special MFi
                        //    names like "Touchpad Button"/"Share Button"
                        //    that don't embed a digit in their name.
                        // 2) Fall back to the static knownButtonMap for
                        //    common synthetic names.
                        // 3) As a last resort use extractButtonIndex which
                        //    only works when the name happens to embed a
                        //    digit ("Button 5"). This used to be the only
                        //    path, which silently mapped every extra
                        //    button to slot 0 (= A button) during scan -
                        //    the user complained that paddle/FN/Home/mute
                        //    presses were "not detected" when in fact they
                        //    were detected but mapped to the wrong slot.
                        let btnIndex: Int
                        if let cached = self.cachedExtraButtons[index]?
                            .first(where: { ObjectIdentifier($0.0) == buttonID }) {
                            btnIndex = cached.1
                        } else if let known = Self.knownButtonMap[name] {
                            btnIndex = known
                        } else {
                            btnIndex = self.extractButtonIndex(from: name)
                        }
                        let event = InputEvent.button(btnIndex)
                        self.scanCallback?(event)
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

    /// Keep a controller's input stream active during normal (non-scan)
    /// operation. On macOS 26 the GameController framework only refreshes a
    /// profile's pollable `.value`s while a handler is attached to it. The app
    /// reads state by polling (`readControllerState`) every frame, so with no
    /// handler installed every poll returns zero, and the live visualizer, the
    /// mapping engine, and the connect-time light all see a dead controller.
    /// Installing a profile-level handler keeps the values live. It is
    /// deliberately a no-op: the 30 Hz poll does the actual reading. The scan
    /// path installs its own per-element handlers on top and clears them on
    /// exit; this profile-level handler is independent and survives that.
    private func installLiveInputHandler(for controller: GCController) {
        if let pad = controller.extendedGamepad {
            pad.valueChangedHandler = { _, _ in }
        } else {
            // Profile-only devices (solo Joy-Con orientations, remote-class or
            // adaptive hardware) need per-element no-op handlers for the same
            // macOS 26 keep-values-fresh reason. Without this, the first scan's
            // teardown left them permanently reading zeros until replug.
            let profile = controller.physicalInputProfile
            for (_, button) in profile.buttons {
                button.valueChangedHandler = { _, _, _ in }
            }
            for (_, axis) in profile.axes {
                axis.valueChangedHandler = { _, _ in }
            }
            for (_, dpad) in profile.dpads {
                dpad.valueChangedHandler = { _, _, _ in }
            }
        }
    }

    // MARK: - Polling (for mapping engine)

    func readControllerState(at index: Int) -> ControllerState? {
        // Steam Controllers occupy the virtual slot just past the last
        // MFi controller. When a binding targets that slot we ask the
        // SteamControllerService for its synthesized ControllerState.
        if let steamIndex = steamControllerSlot, index == steamIndex {
            return SteamControllerService.shared.makeControllerState()
        }
        // A real MFi controller at this slot always takes precedence over a
        // raw-HID entry at the same index, so a hot-plugged MFi controller can
        // never be shadowed by a raw-HID pad that was assigned a low slot while
        // no MFi controller was present. Slots at or past the MFi count belong
        // to Steam (handled above) or to raw-HID gamepads, whose state comes
        // from the lock-protected snapshot the HID report callback wrote.
        guard index < connectedControllers.count else {
            if let gamepad = rawHIDGamepadSlots[index] {
                return gamepad.state
            }
            return nil
        }
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

            // --- DualSense Edge supplemental buttons ---
            // Apple's GameController framework doesn't expose the
            // Edge's paddles, FN1/FN2, or microphone-mute. We read
            // them directly via IOHIDManager in
            // `DualSenseSupplementService` and merge the result here
            // so existing bindings against indices 15/16/17/20/21
            // light up the same way native MFi buttons do. Skipped
            // for non-DualSense slots (the dictionary is empty for
            // those, so the loop is a no-op).
            if dualSenseSlots.contains(index) {
                let supplement = DualSenseSupplementService.shared.anySupplementalButtons()
                for (btnIndex, value) in supplement where value > 0.5 {
                    state.buttons[btnIndex] = value
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

            // --- Motion sensors (gyro + accel + attitude) ---
            // Populated only when the controller actually exposes motion.
            // Bindings of type `.motion` consume these via MappingEngine.
            // Drift correction: subtract the per-controller calibration
            // baseline (zero gyro/accel at rest) so a still controller
            // reads exactly 0 on every motion channel.
            if let motion = controller.motion {
                let key = MotionCalibrationService.identityKey(for: controller)
                // Guard the accel read like the gyro block below: a controller
                // that exposes motion but not gravity/user-acceleration returns
                // undefined values here, which would feed NaN/garbage into the
                // calibration and motion bindings.
                if motion.hasGravityAndUserAcceleration {
                    let (ax, ay, az) = MotionCalibrationService.shared.correctedAccel(
                        x: Float(motion.userAcceleration.x),
                        y: Float(motion.userAcceleration.y),
                        z: Float(motion.userAcceleration.z),
                        forKey: key)
                    state.motion[.accelX] = ax
                    state.motion[.accelY] = ay
                    state.motion[.accelZ] = az
                }
                if motion.hasRotationRate {
                    let (gx, gy, gz) = MotionCalibrationService.shared.correctedGyro(
                        x: Float(motion.rotationRate.x),
                        y: Float(motion.rotationRate.y),
                        z: Float(motion.rotationRate.z),
                        forKey: key)
                    state.motion[.gyroX] = gx
                    state.motion[.gyroY] = gy
                    state.motion[.gyroZ] = gz
                }
                if motion.hasAttitude {
                    // Convert quaternion (x,y,z,w) to Euler roll/pitch/yaw.
                    // The output is in radians; downstream code normalizes
                    // by dividing by π to land in roughly [-1, 1].
                    let q = motion.attitude
                    let qx = Float(q.x), qy = Float(q.y), qz = Float(q.z), qw = Float(q.w)
                    let roll  = atan2(2 * (qw * qx + qy * qz),
                                      1 - 2 * (qx * qx + qy * qy))
                    let pitchArg = 2 * (qw * qy - qz * qx)
                    let pitch = asin(max(-1.0, min(1.0, pitchArg)))
                    let yaw   = atan2(2 * (qw * qz + qx * qy),
                                      1 - 2 * (qy * qy + qz * qz))
                    state.motion[.rollAngle]  = roll  / .pi   // ≈ -1...1
                    state.motion[.pitchAngle] = pitch / (.pi / 2)
                    state.motion[.yawAngle]   = yaw   / .pi
                }
            }
        } else {
            // Physical input profile fallback for non-standard controllers.
            // CRITICAL: resolve names with the SAME chain the scan path uses
            // (knownButtonMap first, digit extraction as last resort). The old
            // digit-only fallback mapped every letter-named button ("Button B")
            // to index 0, so anything scanned on these devices could never
            // fire at runtime.
            let profile = controller.physicalInputProfile
            for (name, button) in profile.buttons {
                let idx = Self.knownButtonMap[name] ?? extractButtonIndex(from: name)
                state.buttons[idx] = button.value
            }
            for (name, axis) in profile.axes {
                let idx = extractAxisIndex(from: name)
                state.axes[idx] = axis.value
            }
            // D-pads were previously ignored here entirely, leaving hats dead
            // on profile-only devices. GCControllerDirectionPad's yAxis is
            // already up-positive (the app's hat convention).
            for (hatIdx, entry) in profile.dpads.sorted(by: { $0.key < $1.key }).enumerated() {
                state.hats[hatIdx] = (x: entry.value.xAxis.value, y: entry.value.yAxis.value)
            }
        }

        return state
    }

    // MARK: - Helpers

    /// Slots whose controller is a DualSense / DualSense Edge, computed once
    /// per connection in `cacheExtraButtons`. Read every poll frame by
    /// `readControllerState` for the supplement merge.
    private var dualSenseSlots: Set<Int> = []

    /// Controllers whose press logger is already installed. Without this,
    /// every `refreshControllers()` (one per hotplug event) re-wrapped each
    /// button's handler in one more pass-through closure, growing the handler
    /// chain without bound.
    private var pressLoggerWired: Set<ObjectIdentifier> = []

    // MARK: - Physical press diagnostic log

    /// Install a pass-through press logger on every button in the
    /// physical input profile. Fires alongside (NOT instead of) the
    /// scan / read handlers so we can show the user EXACTLY which name
    /// Apple's framework reports for the button they just pressed. The
    /// Settings > Controllers diagnostic surfaces this list.
    private func installPhysicalPressLogger(for controller: GCController, slot: Int) {
        // Idempotent: refreshControllers runs on every hotplug, and wiring a
        // second time would re-wrap each prior handler in another pass-through
        // closure, growing the chain (and per-press cost) without bound. The
        // closure resolves the slot at fire time so the log stays correct when
        // slots reshuffle after another controller disconnects.
        let identity = ObjectIdentifier(controller)
        guard !pressLoggerWired.contains(identity) else { return }
        pressLoggerWired.insert(identity)
        let profile = controller.physicalInputProfile
        for (name, button) in profile.buttons {
            // Skip the composite "Direction Pad", thumbsticks, etc.
            if Self.ignoredProfileNames.contains(where: { name.contains($0) }) { continue }
            // Capture any prior handler (set by setupScanHandlers or our
            // cache loop) so we can call it after logging.
            let prior = button.pressedChangedHandler
            let mappedIndex = Self.knownButtonMap[name]
                ?? (cachedExtraButtons[slot]?.first(where: { ObjectIdentifier($0.0) == ObjectIdentifier(button) })?.1)
            button.pressedChangedHandler = { [weak self, weak controller] btn, value, pressed in
                if pressed {
                    Task { @MainActor in
                        guard let self else { return }
                        let liveSlot = controller.flatMap { c in
                            self.connectedControllers.firstIndex(where: { $0 === c })
                        } ?? slot
                        self.logPhysicalPress(name: name, slot: liveSlot, mappedIndex: mappedIndex)
                    }
                }
                prior?(btn, value, pressed)
            }
        }
    }

    private func logPhysicalPress(name: String, slot: Int, mappedIndex: Int?) {
        PhysicalPressLogStore.shared.log(slot: slot, name: name, mappedIndex: mappedIndex)
    }

    // MARK: - Raw active inputs (drives editor highlight without a running preset)

    /// Threshold for considering an analog axis "active". Matches the engine's
    /// defaultAxisThreshold so highlight and binding fire feel the same.
    private let rawActiveAxisThreshold: Float = 0.5
    private let rawActiveHatThreshold: Float = 0.5

    /// Minimum time a detected input stays in `rawActiveInputs` after we
    /// last saw it pressed. Even a single-frame tap (which a slow polling
    /// loop would miss entirely) lingers long enough to be visible as the
    /// green row highlight in the editor.
    private let rawActiveLingerSeconds: TimeInterval = 0.20

    /// Per-input expiry timestamps. We keep an entry in `rawActiveInputs`
    /// as long as its expiry is in the future.
    private var rawActiveExpiry: [String: Date] = [:]

    private func startRawActiveInputsPolling() {
        // 30 Hz polling - catches quick taps a 10 Hz loop would miss. Cheap
        // because we only read controller state and update a Set.
        rawActivePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // The timer fires on RunLoop.main (main thread = main actor), so run
            // inline instead of spawning a Task per tick (an allocation + hop
            // 30x/second). The fast-path guard inside then runs with zero cost.
            MainActor.assumeIsolated {
                self?.refreshRawActiveInputs()
            }
        }
        if let t = rawActivePollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    /// Snapshot every connected controller's current state and turn pressed
    /// buttons / deflected axes / hat directions into the serialized strings
    /// the editor uses to match binding rows. Each detected input gets a
    /// 200 ms expiry so quick taps remain visible.
    private func refreshRawActiveInputs() {
        // Fast path: when no input source is connected and there is no
        // lingering highlight state or visualizer snapshot left to clear,
        // there is nothing to read or update. Skipping the whole body means
        // the 30 Hz timer costs effectively nothing on the welcome screen or
        // any time every controller is unplugged. The guard is conservative:
        // it only returns when a scan is not running and every piece of
        // derived state is already empty, so no stale highlight or snapshot
        // can be left behind.
        if connectedControllers.isEmpty,
           steamControllerSlot == nil,
           rawHIDGamepadSlots.isEmpty,
           !isScanning,
           rawActiveExpiry.isEmpty,
           rawActiveInputs.isEmpty,
           currentStates.isEmpty {
            return
        }

        // Reuse mutable scratch containers across ticks. Previously this
        // method allocated fresh Set<String> and [Int: ControllerState]
        // every 30 Hz frame, generating ~60 collection allocations per
        // second just for the editor highlight bookkeeping.
        scratchFreshlyActive.removeAll(keepingCapacity: true)
        scratchSnapshots.removeAll(keepingCapacity: true)

        // Real MFi controllers
        for i in connectedControllers.indices {
            guard let state = readControllerState(at: i) else { continue }
            scratchSnapshots[i] = state
            accumulate(into: &scratchFreshlyActive, state: state)
            // Bridge any DualSense / DualShock 4 touchpad data the
            // GameController framework reports through to the touchpad
            // pipeline (see notes in feedTouchpadFromController).
            feedTouchpadFromController(connectedControllers[i], slot: i)
        }
        // Steam Controller virtual slot
        if let slot = steamControllerSlot, let state = readControllerState(at: slot) {
            scratchSnapshots[slot] = state
            accumulate(into: &scratchFreshlyActive, state: state)
        }
        // Raw HID gamepads (8BitDo XInput, Xbox 360 wired, etc.)
        for (slot, _) in rawHIDGamepadSlots {
            guard let state = readControllerState(at: slot) else { continue }
            scratchSnapshots[slot] = state
            accumulate(into: &scratchFreshlyActive, state: state)
        }
        // ControllerState isn't Equatable (its hat tuples can't auto-
        // derive it), so we always assign. Cost is negligible for 1-2
        // controllers at 30 Hz; copy is a single shallow Dict copy.
        currentStates = scratchSnapshots

        // Bridge supplemental inputs into the scan flow. Some buttons -
        // notably the PS / Home button on DualSense under macOS 26's
        // Game Mode - are swallowed by Apple's framework before our
        // typed pressedChangedHandlers fire. Our raw HID supplement
        // still sees those presses and merges them into state.buttons;
        // we detect a 0→1 transition here and fire the scanCallback so
        // the binding editor's Scan button can still capture them.
        if isScanning, let cb = scanCallback {
            // Find a freshly-active input that wasn't active last tick.
            // Avoid `Set.subtracting`'s new-Set allocation by looping.
            var firedKey: String?
            for key in scratchFreshlyActive where !rawActiveInputs.contains(key) {
                firedKey = key
                break
            }
            if let first = firedKey, let event = InputEvent.parse(first) {
                cb(event)
            }
        }

        // Stamp expiry timestamps for everything currently pressed.
        let now = Date()
        let expiryDate = now.addingTimeInterval(rawActiveLingerSeconds)
        for key in scratchFreshlyActive {
            rawActiveExpiry[key] = expiryDate
        }
        // Drop entries whose expiry has passed. Collect into a reused scratch
        // array (not a fresh `Array(rawActiveExpiry.keys)` every 30 Hz tick) to
        // avoid mutating-during-iteration UB with zero per-tick allocation.
        scratchExpiredKeys.removeAll(keepingCapacity: true)
        for (key, date) in rawActiveExpiry where date <= now {
            scratchExpiredKeys.append(key)
        }
        for key in scratchExpiredKeys {
            rawActiveExpiry.removeValue(forKey: key)
        }
        // Build the published Set only when the membership actually
        // changed. Skip the equality check on the common steady-state
        // tick where no new keys were added or expired.
        if rawActiveExpiry.count != rawActiveInputs.count
            || !rawActiveInputs.isSuperset(of: rawActiveExpiry.keys) {
            rawActiveInputs = Set(rawActiveExpiry.keys)
        }
    }

    /// Scratch containers reused by `refreshRawActiveInputs` so the
    /// 30 Hz loop doesn't allocate fresh collections on every tick.
    /// Sit at the type level next to other state so they're not
    /// re-allocated on every call.
    private var scratchFreshlyActive: Set<String> = []
    /// Reused across 30 Hz ticks to collect expired raw-active keys without a
    /// fresh Array allocation per tick.
    private var scratchExpiredKeys: [String] = []
    private var scratchSnapshots: [Int: ControllerState] = [:]

    /// Read touchpad finger positions from a `GCDualSenseGamepad` or
    /// `GCDualShockGamepad` profile and push them into TouchpadService.
    /// No-op for any controller that doesn't expose a touchpad.
    ///
    /// macOS 14+ exposes the DualSense / DS4 touchpad through
    /// `touchpadPrimary` / `touchpadSecondary` direction pads on the
    /// typed extendedGamepad subclass. Reading them this way works
    /// even when `gamecontrollerd` has the device open exclusively
    /// and our TouchpadHelper subprocess sees zero bytes.
    ///
    /// Slot is accepted for symmetry but not used yet; TouchpadService
    /// is single-instance and tracks one device's worth of state. If
    /// we ever support two touchpads simultaneously, we route by slot.
    /// Wire `valueChangedHandler` on a controller's touchpad direction
    /// pads so finger motion is pushed into TouchpadService at the
    /// controller's native HID rate (≈1000 Hz USB DualSense, ≈250 Hz
    /// Bluetooth) instead of the 30 Hz `refreshRawActiveInputs` poll.
    ///
    /// The 30 Hz poll path stays as a fallback for controllers that
    /// don't take the typed-subclass branch here (generic dpads scan in
    /// `feedTouchpadFromController`). Dual writes are safe because
    /// TouchpadService.ingestGameControllerTouchpad locks the underlying
    /// state and the latest write wins.
    private func installTouchpadHandlers(for controller: GCController, slot: Int) {
        guard let pad = controller.extendedGamepad else { return }

        if let ds = pad as? GCDualSenseGamepad {
            attachTouchpadHandlers(primary: ds.touchpadPrimary,
                                   secondary: ds.touchpadSecondary)
        } else if let ds4 = pad as? GCDualShockGamepad {
            attachTouchpadHandlers(primary: ds4.touchpadPrimary,
                                   secondary: ds4.touchpadSecondary)
        }
    }

    /// Shared handler installer used by both the DualSense and DS4
    /// branches. Pulls the pair's latest (x, y) on every change and
    /// pushes both fingers through TouchpadService as a single
    /// transaction so a one-finger update doesn't latch finger 1 active.
    private func attachTouchpadHandlers(primary: GCControllerDirectionPad,
                                        secondary: GCControllerDirectionPad?) {
        // Capture the optional secondary outside the closure so the
        // closure body can read it without re-checking the type each
        // event. Apple guarantees these direction pad objects are
        // stable for the controller's lifetime.
        let sec = secondary
        let push: () -> Void = {
            let p1x = primary.xAxis.value
            let p1y = primary.yAxis.value
            let p1Active = abs(p1x) > 0.001 || abs(p1y) > 0.001
            let p2x = sec?.xAxis.value ?? 0
            let p2y = sec?.yAxis.value ?? 0
            let p2Active = sec != nil && (abs(p2x) > 0.001 || abs(p2y) > 0.001)
            TouchpadService.shared.ingestGameControllerTouchpad(
                f0Active: p1Active, f0NormalizedX: p1x, f0NormalizedY: p1y,
                f1Active: p2Active, f1NormalizedX: p2x, f1NormalizedY: p2y
            )
        }
        primary.valueChangedHandler = { _, _, _ in push() }
        secondary?.valueChangedHandler = { _, _, _ in push() }
    }

    private func feedTouchpadFromController(_ controller: GCController, slot: Int) {
        guard let pad = controller.extendedGamepad else { return }

        // Typed subclasses (DualSense / DualShock 4) are handled by
        // `installTouchpadHandlers`'s event-driven path which runs at
        // controller-native rate. Skip them here so we don't double-
        // write and don't waste cycles re-reading them every 33 ms.
        if pad is GCDualSenseGamepad || pad is GCDualShockGamepad {
            return
        }

        var f0Active = false
        var f0X: Float = 0
        var f0Y: Float = 0
        var f1Active = false
        var f1X: Float = 0
        var f1Y: Float = 0
        var sourced = false

        // Generic fallback for any other touchpad-capable controller
        // Apple exposes via the physical input profile. Some third-
        // party gamepads and future controllers ship with a touchpad
        // surface registered under names like "Touchpad 1" / "Touch 1".
        // Walk `pad.dpads` looking for those name patterns and use
        // whichever we find. This means future hardware that exposes
        // its surface through the standard profile will Just Work
        // without us shipping a new typed subclass per device.
        for (name, dpad) in pad.dpads {
            let lower = name.lowercased()
            guard lower.contains("touchpad") || lower.contains("touch ")
                    || lower.contains("trackpad") else { continue }
            let x = dpad.xAxis.value
            let y = dpad.yAxis.value
            let active = abs(x) > 0.001 || abs(y) > 0.001
            if lower.contains("2") || lower.contains("secondary") {
                f1X = x; f1Y = y; f1Active = active
            } else {
                f0X = x; f0Y = y; f0Active = active
            }
            sourced = true
        }

        guard sourced else { return }

        TouchpadService.shared.ingestGameControllerTouchpad(
            f0Active: f0Active, f0NormalizedX: f0X, f0NormalizedY: f0Y,
            f1Active: f1Active, f1NormalizedX: f1X, f1NormalizedY: f1Y
        )
    }

    // Memoized serialized input keys. accumulate() runs at 30 Hz for each
    // currently-active input; without these caches it rebuilt an InputEvent and
    // an interpolated String every tick. The key for a given (kind, index,
    // direction) never changes, so cache it on first use. Touched only on the
    // main actor (this is a @MainActor class), so plain dictionaries are safe.
    private var btnKeyCache: [Int: String] = [:]
    private var axisPosKeyCache: [Int: String] = [:]
    private var axisNegKeyCache: [Int: String] = [:]
    private var hatKeyCache: [Int: (u: String, d: String, l: String, r: String)] = [:]

    private func btnKey(_ i: Int) -> String {
        if let k = btnKeyCache[i] { return k }
        let k = InputEvent.button(i).serialized
        btnKeyCache[i] = k
        return k
    }
    private func axisKey(_ i: Int, positive: Bool) -> String {
        if positive {
            if let k = axisPosKeyCache[i] { return k }
            let k = InputEvent.axis(i, direction: .positive).serialized
            axisPosKeyCache[i] = k
            return k
        }
        if let k = axisNegKeyCache[i] { return k }
        let k = InputEvent.axis(i, direction: .negative).serialized
        axisNegKeyCache[i] = k
        return k
    }
    private func hatKeys(_ i: Int) -> (u: String, d: String, l: String, r: String) {
        if let k = hatKeyCache[i] { return k }
        let k = (InputEvent.hat(i, direction: .up).serialized,
                 InputEvent.hat(i, direction: .down).serialized,
                 InputEvent.hat(i, direction: .left).serialized,
                 InputEvent.hat(i, direction: .right).serialized)
        hatKeyCache[i] = k
        return k
    }

    private func accumulate(into set: inout Set<String>, state: ControllerState) {
        for (index, value) in state.buttons where value > 0.5 {
            set.insert(btnKey(index))
        }
        for (index, value) in state.axes {
            if value > rawActiveAxisThreshold {
                set.insert(axisKey(index, positive: true))
            } else if value < -rawActiveAxisThreshold {
                set.insert(axisKey(index, positive: false))
            }
        }
        for (index, hat) in state.hats {
            let keys = hatKeys(index)
            if hat.y > rawActiveHatThreshold { set.insert(keys.u) }
            if hat.y < -rawActiveHatThreshold { set.insert(keys.d) }
            if hat.x < -rawActiveHatThreshold { set.insert(keys.l) }
            if hat.x > rawActiveHatThreshold { set.insert(keys.r) }
        }
    }

    // MARK: - Steam Controller integration

    /// Poll `SteamControllerService` at 2 Hz, syncing the synthesized virtual
    /// slot index + ControllerInfo so the rest of the app (sidebar status
    /// bar, preset detail metadata, binding row) sees a Steam Controller
    /// the same way it sees any MFi gamepad.
    private func startSteamControllerWatch() {
        steamWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncSteamControllerSlot()
            }
        }
        if let t = steamWatchTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func syncSteamControllerSlot() {
        let isConnected = SteamControllerService.shared.isConnected
        let desiredSlot = isConnected ? connectedControllers.count : nil

        if desiredSlot == steamControllerSlot { return }

        // Clean up any prior virtual entry.
        if let oldSlot = steamControllerSlot {
            controllerDetails.removeValue(forKey: oldSlot)
            controllerNames.removeValue(forKey: oldSlot)
        }

        steamControllerSlot = desiredSlot

        if let slot = desiredSlot {
            controllerNames[slot] = "Steam Controller"
            controllerDetails[slot] = ControllerInfo(
                name: "Steam Controller",
                productCategory: "Vendor HID",
                hasExtendedGamepad: false,
                hasLight: false,
                hasBattery: false,
                batteryLevel: nil,
                batteryState: nil,
                buttonCount: 23,
                axisCount: 6,
                supportsMotion: true,
                hasTouchpad: true,           // two trackpads
                hasMicroGamepad: false,
                hasAdaptiveTriggers: false,
                physicalButtonNames: SteamControllerButton.allCases.map(\.displayName),
                brand: .steamController
            )
        }
    }

    // MARK: - Raw HID Gamepad integration

    /// Poll `RawHIDGamepadService` at 2 Hz, allocating + reclaiming slot
    /// indices for HID gamepads the same way `syncSteamControllerSlot`
    /// does for the Steam Controller. Each detected gamepad gets a slot
    /// just past the MFi + Steam slots so existing preset slot
    /// indexes for native controllers stay stable.
    private func startRawHIDGamepadWatch() {
        // Idempotent. Stored on the instance so we don't leak timers
        // if the service is ever recreated (a previous version of
        // this method dropped the local `let timer` reference, which
        // kept polling forever in zombie service instances).
        rawHIDWatchTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncRawHIDGamepadSlots()
            }
        }
        rawHIDWatchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func syncRawHIDGamepadSlots() {
        let attached = RawHIDGamepadService.shared.connectedGamepads
        let baseIndex = connectedControllers.count + (steamControllerSlot != nil ? 1 : 0)

        // Build the desired (slot → gamepad) mapping from the current
        // attach list. Stable ordering: keep gamepads already mapped at
        // their current slot, then append any newcomers.
        var desired: [Int: RawHIDGamepad] = [:]
        let previouslyMappedIDs = Set(rawHIDGamepadSlots.values.map { $0.id })

        // First pass: preserve an existing slot only when it is still valid,
        // i.e. at or above the current base index. A slot assigned while no
        // MFi controller was present can fall below baseIndex once one
        // connects; keeping it there would let the raw-HID pad shadow the real
        // MFi controller, so such pads fall through to the second pass and get
        // re-based onto a free slot above the MFi range.
        var nextSlot = baseIndex
        var reservedSlots: Set<Int> = []
        for gamepad in attached where previouslyMappedIDs.contains(gamepad.id) {
            if let (oldSlot, _) = rawHIDGamepadSlots.first(where: { $0.value.id == gamepad.id }),
               oldSlot >= baseIndex {
                desired[oldSlot] = gamepad
                reservedSlots.insert(oldSlot)
            }
        }

        // Second pass: assign every gamepad not yet placed (newcomers and any
        // re-based from a now-invalid low slot) to the lowest free slot at or
        // above baseIndex.
        for gamepad in attached where !desired.values.contains(where: { $0.id == gamepad.id }) {
            while reservedSlots.contains(nextSlot) { nextSlot += 1 }
            desired[nextSlot] = gamepad
            reservedSlots.insert(nextSlot)
            nextSlot += 1
        }

        // Apply if changed. Equality is by slot key set + per-slot id.
        let changed = desired.count != rawHIDGamepadSlots.count
            || desired.contains(where: { rawHIDGamepadSlots[$0.key]?.id != $0.value.id })
        if changed {
            // Detach controller info for slots that are no longer used.
            let removedSlots = Set(rawHIDGamepadSlots.keys).subtracting(desired.keys)
            for slot in removedSlots {
                controllerDetails.removeValue(forKey: slot)
                controllerNames.removeValue(forKey: slot)
            }
            rawHIDGamepadSlots = desired
        }

        // Publish controller info for each active slot so the rest of the app
        // sees these gamepads like any other controller. This also runs when
        // the slot map did NOT change but the metadata is missing, because
        // refreshControllers wipes controllerNames/controllerDetails on every
        // MFi hot-plug and only repopulates the MFi slots; republishing here
        // keeps an unrelated MFi change from stranding the raw-HID slots without
        // metadata. The per-slot guard skips the writes in steady state (already
        // published, unchanged) so there is no spurious @Published churn.
        for (slot, gamepad) in rawHIDGamepadSlots where changed || controllerDetails[slot] == nil {
            let names = gamepad.profile?.physicalButtonNames
                ?? ControllerProfileDatabase.xinputButtonNames
            controllerNames[slot] = gamepad.displayName
            controllerDetails[slot] = ControllerInfo(
                name: gamepad.displayName,
                productCategory: "Raw HID",
                hasExtendedGamepad: true,
                hasLight: false,
                hasBattery: false,
                batteryLevel: nil,
                batteryState: nil,
                buttonCount: names.count,
                axisCount: 6,
                supportsMotion: false,
                hasTouchpad: false,
                hasMicroGamepad: false,
                hasAdaptiveTriggers: false,
                physicalButtonNames: names,
                brand: .unknown
            )
        }
    }

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
