import Foundation
import Combine
import AppKit
import GameController

/// The core engine that reads controller inputs and fires output actions.
/// 120Hz polling with debug logging capability.
@MainActor
class MappingEngine: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var activePreset: Preset?
    /// Effective poll rate of the active timer in Hz. Driven by
    /// `installPollTimer()` so the UI (DebugLogView footer, Settings
    /// readout) always shows the *actual* rate, not the saved
    /// default. 120 is the same default we apply in installPollTimer
    /// when no setting is saved yet.
    @Published var currentPollHz: Int = 120
    /// Mirror of currently-active inputs. NOT @Published - observers update
    /// via the throttled `activeInputsPublished` instead so a fast-changing
    /// joystick does not re-render the editor 120 times per second.
    var activeInputs: Set<String> = []
    @Published var activeInputsPublished: Set<String> = []
    private var activeInputsLastFlush: CFTimeInterval = -.infinity
    @Published var debugLog: [(text: String, joystickIndex: Int?)] = []  // Rolling debug log visible in UI

    private var controllerService: GameControllerService
    private var pollTimer: Timer?

    /// Subscription to `ExternalInputDeviceService.events`. Established in
    /// `start()` and cancelled in `stop()` so the engine only listens to
    /// keyboards / mice while a preset is active.
    private var externalEventSubscription: AnyCancellable?
    /// Tracks the last seen power-source label so we can re-install
    /// the poll timer only when the user actually plugs / unplugs.
    /// Without this gate the @Published source string would trigger an
    /// applyPollRate on every IOPS refresh tick (every 5 s).
    private var powerSourceSubscription: AnyCancellable?
    private var controllerListSubscription: AnyCancellable?
    private var lastSeenPowerSource: String?

    /// Per-device map of currently-held HID keyboard usages. Updated by the
    /// IOHIDManager callback in `ExternalInputDeviceService`; read by the
    /// 120 Hz poll loop the same way it reads controller state.
    private var externalKeysDown: [String: Set<Int>] = [:]
    /// Per-device map of currently-held mouse button indices.
    private var externalMouseButtonsDown: [String: Set<Int>] = [:]
    /// Accumulated mouse motion deltas since the last poll frame, per device.
    /// Reset to zero at the start of every poll frame.
    private var externalMouseDX: [String: Int] = [:]
    private var externalMouseDY: [String: Int] = [:]
    /// Accumulated scroll wheel ticks since the last poll frame, per device.
    private var externalScrollDX: [String: Int] = [:]
    private var externalScrollDY: [String: Int] = [:]

    private var activeStates: [Int: Set<String>] = [:]
    private let defaultAxisThreshold: Float = 0.25
    private let hatThreshold: Float = 0.5

    // Toggle mode state: tracks which bindings are currently toggled on
    private var toggleStates: [String: Bool] = [:]
    // Turbo state: tracks last fire time for turbo bindings
    /// Last fire time per turbo binding, expressed as CACurrentMediaTime
    /// seconds (monotonic, allocation-free). Was previously [String: Date]
    /// which forced a fresh Date() allocation on every turbo poll.
    private var turboTimestamps: [String: CFTimeInterval] = [:]
    /// bindKeys whose macro chain is currently executing. Used to
    /// suppress a fresh executeMacro() call on a re-press while the
    /// previous chain is still running, preventing parallel macro
    /// threads that doubled outputs.
    private var macrosInFlight: Set<String> = []
    // Cache of serialized input keys to avoid repeated string allocations at 120Hz
    private var serializedKeyCache: [UUID: String] = [:]
    /// Cache for the toggle/turbo/macro bind key ("slot:uuid") so a preset with
    /// those bindings doesn't rebuild binding.id.uuidString every 120 Hz frame.
    private var bindKeyCache: [UUID: String] = [:]

    /// Monotonically increasing counter bumped on every start()/stop().
    /// Background blocks (macros, turbo release) capture this at schedule
    /// time and bail before re-entering the engine when the value has
    /// changed - prevents stuck keys after stop() invalidates the poll
    /// timer but in-flight macro / turbo blocks still try to release a
    /// key from a preset that's no longer active.
    private var engineGeneration: Int = 0

    /// Scratch Sets reused across poll frames so the 120 Hz hot path
    /// doesn't allocate a fresh `Set<String>` per joystick per tick.
    /// At 120 Hz × 4 joysticks × small bindings each, the old code
    /// burned ~3,840 Set allocations / sec just on highlight
    /// bookkeeping. `removeAll(keepingCapacity:)` keeps the hash
    /// table allocated and just zeroes the count.
    private var scratchActiveSet: Set<String> = []
    private var scratchAllActiveSet: Set<String> = []

    private var debugEnabled = true
    private var debugLineCount = 0

    /// Internal buffer the polling loop writes to without triggering UI
    /// re-renders. A separate timer flushes this into `debugLog` (which is
    /// @Published) at a much slower rate so the editor and other observers
    /// of `mappingEngine` do not re-render on every input event.
    private var pendingLog: [(text: String, joystickIndex: Int?)] = []
    /// Set when `pendingLog` gains a new entry. Lets flushPendingLog skip the
    /// @Published mirror assignment on idle 5 Hz ticks, so DebugLogView does
    /// not re-render and re-filter the whole log when nothing has changed.
    private var pendingLogDirty = false
    private var logFlushTimer: Timer?
    /// True while the active preset retains TouchpadService. Tracked
    /// separately so stop() only releases when start() retained.
    private var usesTouchpadInput = false
    /// Mirrors usesTouchpadInput for cursor-region presets: tracks
    /// whether we asked CursorRegionService to poll the cursor, so
    /// stop() balances the beginTracking() call exactly once.
    private var usesCursorRegionInput = false

    /// When true, the engine keeps polling and updating `activeInputs` so the
    /// editor's row highlights and the touchpad calibration UI keep working,
    /// but it does NOT fire any outputs (no mouse motion, no keystrokes, no
    /// MIDI). Set while the preset editor is open so a touchpad-as-mouse
    /// preset can't fling the cursor across the screen while the user is
    /// trying to configure it.
    @Published var outputsPaused: Bool = false {
        didSet {
            if outputsPaused {
                // Release any output state that was currently held so the
                // user doesn't end up with a stuck key or held mouse button
                // the moment we pause.
                driveProcessor.releaseAll()
                InputSimulator.shared.releaseAll()
                MIDIService.shared.releaseAllNotes()
                // Clear the logical toggle bookkeeping too. The physical outputs
                // were just released, so leaving toggleStates marked "on" would
                // desync them: an un-pause would not re-press a held toggle, and
                // the next press would immediately toggle it back off.
                toggleStates.removeAll()
                pendingMouseDeltaX = 0
                pendingMouseDeltaY = 0
                mouseCarryX = 0
                mouseCarryY = 0
                pendingScrollDeltaX = 0
                pendingScrollDeltaY = 0
            }
        }
    }

    init(controllerService: GameControllerService) {
        self.controllerService = controllerService
        installControllerDisconnectObserver()
        installSleepWakeObservers()
    }

    /// Release every synthesized output when the machine sleeps, and refresh
    /// the controller set on wake. Without this, a key or mouse button held
    /// by a binding at the moment of sleep stayed logically down through the
    /// nap, and Bluetooth pads that dropped during sleep kept stale slots
    /// until the user opened the controller popover by hand.
    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.driveProcessor.releaseAll()
                InputSimulator.shared.releaseAll()
                MIDIService.shared.releaseAllNotes()
                // Reset edge detection, toggle latches, and deferred
                // tap/hold state so held inputs re-press and nothing
                // resolves against a pre-sleep press time after wake.
                self.activeStates.removeAll()
                self.toggleStates.removeAll()
                self.deferredPressStart.removeAll()
                self.holdFired.removeAll()
                self.lastTapTime.removeAll()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.controllerService.refreshControllers()
            }
        }
    }

    /// Drop cached active-input / toggle / turbo / macro state for any
    /// controller slot that has gone out of range whenever the controller set
    /// changes. Without this, a controller that disconnects mid-press leaves
    /// orphaned bindKeys in toggleStates + turboTimestamps + macrosInFlight;
    /// when the user reconnects to a different slot the same UUID is now under a
    /// fresh bindKey, but the OLD bindKey is still flagged "toggled on", which
    /// shows the binding as latched with no way to turn it off.
    ///
    /// This subscribes to GameControllerService.$connectedControllers rather
    /// than the raw GCControllerDidDisconnect notification. The notification
    /// fired concurrently with GameControllerService's own observer (which
    /// rebuilds connectedControllers and the virtual slots), so reading the slot
    /// count in the handler raced and could see a stale value. Delivered on the
    /// main runloop, the publisher fires AFTER the rebuild, so cleanup always
    /// sees the authoritative slot count. Running on connect too is harmless:
    /// cleanup only wipes slots that are out of range, which a connect can't
    /// create. Storing the cancellable also fixes the previous fire-and-forget
    /// NotificationCenter observer, which was never removed.
    private func installControllerDisconnectObserver() {
        controllerListSubscription = controllerService.$connectedControllers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cleanupAfterControllerDisconnect()
            }
    }

    /// Wipe per-bindKey state for any controller slot whose index is
    /// now out of range. Re-runs after refreshControllers() so the
    /// connected-controllers count is up to date. Belt-and-suspenders:
    /// also release any keys / mouse buttons currently held - if the
    /// disconnect happened while a binding was firing a continuous
    /// output (mouse motion, scroll), the poll loop's next tick won't
    /// see the input as active and the release path normally clears
    /// it, but a stuck simulated key on disconnect is the kind of
    /// stuck-output bug that's hard to undo without a relaunch.
    private func cleanupAfterControllerDisconnect() {
        // Valid slots span the GameController controllers PLUS the Steam
        // virtual slot and any raw-HID gamepads, which occupy higher slot
        // indices. Counting only connectedControllers would treat a raw-HID
        // controller (for example an 8BitDo in a non-MFi mode, which lands at
        // slot 0 when there are zero MFi controllers) as out of range and wipe
        // its live mapping state, breaking its bindings.
        var validSlotCount = controllerService.connectedControllers.count
        if let steamSlot = controllerService.steamControllerSlot {
            validSlotCount = max(validSlotCount, steamSlot + 1)
        }
        if let maxRawSlot = controllerService.rawHIDGamepadSlots.keys.max() {
            validSlotCount = max(validSlotCount, maxRawSlot + 1)
        }
        // Drop activeStates / toggleStates / turboTimestamps / macros
        // for any slot index that no longer corresponds to a connected
        // controller. The dict keys are slot indices for activeStates,
        // and "\(slot):..." strings for the bindKey-keyed ones.
        let staleSlots = activeStates.keys.filter { $0 >= validSlotCount }
        for slot in staleSlots {
            activeStates[slot] = nil
        }
        // Clamp the lower bound so an (unrealistic) >32 controller count
        // can't form an inverted Range, which would trap at runtime.
        let prefixes = (min(validSlotCount, 32)..<32).map { "\($0):" }
        for prefix in prefixes {
            toggleStates = toggleStates.filter { !$0.key.hasPrefix(prefix) }
            turboTimestamps = turboTimestamps.filter { !$0.key.hasPrefix(prefix) }
            macrosInFlight = macrosInFlight.filter { !$0.hasPrefix(prefix) }
        }
        // Release all simulated outputs whenever a controller slot actually
        // dropped (not on a connect, which adds slots and removes none). If
        // several controllers are connected and only one leaves, this also
        // releases outputs the others hold, but the next poll re-presses
        // whatever is genuinely still held; a one-frame blip is far better
        // than a key or mouse button latched down by the controller that left.
        if !staleSlots.isEmpty {
            driveProcessor.releaseAll()
            InputSimulator.shared.releaseAll()
            MIDIService.shared.releaseAllNotes()
            // releaseAll dropped EVERY synthesized output, including ones held
            // by SURVIVING controllers. Clear the edge-detection state so a
            // key genuinely still held re-presses on the next poll frame, and
            // reset toggle latches whose outputs no longer exist so the engine
            // and UI agree (one extra press to re-toggle beats stuck half-on).
            activeStates.removeAll()
            toggleStates.removeAll()
            deferredPressStart.removeAll()
            holdFired.removeAll()
            lastTapTime.removeAll()
        }
    }

    // MARK: - Start / Stop

    func start(with preset: Preset) {
        // The original guard required a controller mapping. With external
        // keyboard / mouse inputs we may legitimately have a preset with no
        // controller-shape bindings, so accept anything that has at least
        // one binding anywhere.
        let hasAnyBinding = preset.joysticks.contains { !$0.bindings.isEmpty }
        // A preset can be pure one-stick driving with no normal bindings; it
        // still needs the poll loop running to produce drive output.
        let hasDriveMode = preset.driveConfig?.enabled == true
        guard hasAnyBinding || hasDriveMode else { return }

        // Make start() idempotent. The "edit the currently-active preset"
        // path re-enters start() with no intervening stop(); without this,
        // reference-counted services (touchpad helper, cursor-region timer,
        // system-stats timer, external-input monitors) get retained again
        // and never balanced, leaking a live subprocess and timers, and
        // stale deferred-tap/toggle state carries into the reloaded preset.
        if isRunning { stop() }

        activePreset = preset
        isRunning = true
        engineGeneration &+= 1
        activeStates.removeAll()
        activeInputs.removeAll()
        toggleStates.removeAll()
        turboTimestamps.removeAll()
        macrosInFlight.removeAll()
        serializedKeyCache.removeAll()
        bindKeyCache.removeAll()
        debugLog.removeAll()
        pendingLog.removeAll()
        debugLineCount = 0

        for i in preset.joysticks.indices {
            activeStates[i] = Set<String>()
        }

        // Pre-build the serialized-input-event cache for every binding
        // so the hot poll loop's `cachedKey(for:)` always hits the
        // cache. Without this, the first ~N polls each pay the
        // serialization cost (string interpolation + Codable
        // resolution) on a freshly-active preset. Building it once
        // here is O(N) on a quiet thread.
        for joystick in preset.joysticks {
            for binding in joystick.bindings {
                if serializedKeyCache[binding.id] == nil {
                    serializedKeyCache[binding.id] = binding.input.serialized
                }
            }
        }

        StatsService.shared.engineStarted(presetName: preset.name)
        log("Engine started with preset: \(preset.name)")
        log("Joysticks: \(preset.joysticks.count), Total bindings: \(preset.joysticks.flatMap(\.bindings).count)")
        log("Connected controllers: \(controllerService.connectedControllers.count)")

        // Spin up the touchpad helper only if the preset actually uses
        // touchpad inputs. Avoids running a subprocess users didn't opt in to.
        let usesTouchpad = preset.joysticks.contains { joystick in
            joystick.bindings.contains {
                $0.input.type == .touchpad || $0.input.type == .touchpadRegion
            }
        }
        if usesTouchpad {
            TouchpadService.shared.retain()
            usesTouchpadInput = true
            log("Touchpad input enabled (started TouchpadHelper)")
        } else {
            usesTouchpadInput = false
        }

        // Cursor-region bindings read the live cursor position. That used
        // to arrive via the system event tap; it now comes from a
        // permission-free NSEvent.mouseLocation poll owned by
        // CursorRegionService. Only start it when the preset actually
        // uses a cursor region, and balance it in stop().
        let usesCursorRegion = preset.joysticks.contains { joystick in
            joystick.bindings.contains { $0.input.type == .cursorRegion }
        }
        if usesCursorRegion {
            CursorRegionService.shared.beginTracking()
            usesCursorRegionInput = true
            log("Cursor region tracking enabled")
        } else {
            usesCursorRegionInput = false
        }

        for (i, ctrl) in controllerService.connectedControllers.enumerated() {
            log("  Controller \(i): \(ctrl.vendorName ?? "Unknown"), hasExtendedGamepad: \(ctrl.extendedGamepad != nil)")
        }

        // Push the preset's light-bar override (if any) so every
        // light-capable controller flashes the preset's color while it's
        // active. We apply temporarily - the slot's stored default color is
        // untouched, so revert in stop() simply re-asserts it.
        if let override = preset.lightBarColor {
            // Stop any running rainbow first, otherwise the 40 Hz cycle would
            // overwrite the preset color on its next frame.
            controllerService.stopAllRGBCycles()
            let bri: UInt8? = preset.lightBarBrightness.map { UInt8(max(0, min(2, $0))) }
            for slot in controllerService.controllerDetails.keys
                where controllerService.controllerDetails[slot]?.hasLight == true {
                controllerService.applyTemporaryLight(
                    at: slot,
                    red: override.floatR,
                    green: override.floatG,
                    blue: override.floatB,
                    brightness: bri)
            }
            log("Applied preset light-bar override (\(override.r),\(override.g),\(override.b))")
        }

        // Polling rate is configurable from Settings → General → Polling Rate.
        // Default 120 Hz balances latency vs. UI cost; 240 doubles latency
        // headroom but cascades twice as many @Published mirror writes, so
        // the editor sheet can hitch. 60 cuts CPU in half but feels laggy
        // for fast-twitch inputs. Stored in UserDefaults so it persists.
        installPollTimer()

        // Per-preset automation: apply CursorGuard overrides + auto-
        // launch any app the preset names. Applied BEFORE the cursor-
        // guard engine flag flips so the new settings are already in
        // place when the service activates.
        CursorGuardService.shared.applyPresetOverride(preset.automation)
        applyPresetAutoLaunch(preset.automation)

        // Let the cursor-guard service know the engine is up so it can
        // hide the system cursor / start its recenter loop if the user
        // enabled those toggles.
        CursorGuardService.shared.engineDidChangeState(running: true)

        // Watch power-source transitions so applyPollRate() runs
        // exactly once per plug / unplug when the user has enabled
        // "Auto-switch on power source" in Settings. Retain the
        // SystemStatsService poll timer for the duration so the
        // source field is actually being updated.
        SystemStatsService.shared.retain()
        lastSeenPowerSource = SystemStatsService.shared.power.source
        powerSourceSubscription = SystemStatsService.shared.$power
            .map(\.source)
            .removeDuplicates()
            .sink { [weak self] newSource in
                guard let self = self else { return }
                let auto = UserDefaults.standard
                    .bool(forKey: "InputConfig.autoPollHzByPower")
                guard auto, newSource != self.lastSeenPowerSource else { return }
                self.lastSeenPowerSource = newSource
                self.applyPollRate()
            }

        // Subscribe to external keyboard / mouse events for the lifetime of
        // this preset. Both paths ride only on the approved Accessibility
        // permission (mouse via a listen-only CGEventTap, keyboard via NSEvent
        // monitors); neither uses Input Monitoring. Our own posted output
        // events carry an own-event marker, so they are filtered out and
        // cannot loop back in as input.
        let usesExtMouse = preset.joysticks.contains { joystick in
            joystick.bindings.contains { $0.input.type == .extMouse }
        }
        let usesExtKey = preset.joysticks.contains { joystick in
            joystick.bindings.contains { $0.input.type == .extKey }
        }
        if usesExtMouse || usesExtKey {
            externalEventSubscription = ExternalInputDeviceService.shared.events
                .receive(on: DispatchQueue.main)
                .sink { [weak self] event in
                    self?.ingestExternalEvent(event)
                }
            // Only start what the preset actually needs.
            if usesExtMouse {
                ExternalInputDeviceService.shared.startMouseMonitoring()
                log("External mouse input enabled")
            }
            if usesExtKey {
                ExternalInputDeviceService.shared.startKeyboardMonitoring()
                log("External keyboard input enabled")
            }
        }

        // Flush log entries to the @Published array at 5 Hz so observers
        // of mappingEngine do not re-render on every input event.
        logFlushTimer?.invalidate()
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flushPendingLog()
            }
        }
        RunLoop.main.add(logFlushTimer!, forMode: .common)
    }

    /// (Re-)installs the controller poll timer using the current
    /// `InputConfig.pollHz` UserDefaults value. Called from start()
    /// during initial install and from `applyPollRate()` when the user
    /// changes the rate in Settings while the engine is already
    /// running. Clamped to [30, 240] to keep CPU sane.
    func installPollTimer() {
        pollTimer?.invalidate()
        let pollHz = resolveEffectivePollHz()
        let pollInterval: TimeInterval = 1.0 / Double(pollHz)
        currentPollHz = pollHz
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // Fires on RunLoop.main (main thread = main actor). Run inline
            // rather than spawning a Task per tick (an allocation + actor hop
            // up to 240x/second) for identical behavior.
            MainActor.assumeIsolated {
                self?.pollControllers()
            }
        }
        pollTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// Reads UserDefaults and decides what rate the engine should
    /// actually run at right now. When auto-switching is off, returns
    /// the saved `pollHz`. When on, returns the battery rate if the
    /// Mac is currently on battery (per SystemStatsService.power.source),
    /// else the AC rate. Clamped to [30, 240].
    private func resolveEffectivePollHz() -> Int {
        let defaults = UserDefaults.standard
        let autoSwitch = defaults.bool(forKey: "InputConfig.autoPollHzByPower")
        let fallback = defaults.object(forKey: "InputConfig.pollHz") as? Int ?? 120
        let rate: Int
        if autoSwitch {
            let acRate = defaults.object(forKey: "InputConfig.pollHzOnAC") as? Int ?? fallback
            let battRate = defaults.object(forKey: "InputConfig.pollHzOnBattery") as? Int ?? 60
            let source = (SystemStatsService.shared.power.source ?? "").lowercased()
            rate = source.contains("battery") ? battRate : acRate
        } else {
            rate = fallback
        }
        return max(30, min(240, rate))
    }

    /// Re-read the poll-rate setting from UserDefaults and rebuild the
    /// timer in place. Safe to call from a SwiftUI `.onChange` while
    /// the engine is running - the only externally visible effect is a
    /// brief one-tick gap while the old timer is torn down and the new
    /// one starts.
    func applyPollRate() {
        guard isRunning else {
            // Engine isn't running - just bump the cached rate so the
            // settings UI's "current rate" label updates immediately.
            currentPollHz = max(30, min(240, UserDefaults.standard.object(forKey: "InputConfig.pollHz")
                                        as? Int ?? 120))
            return
        }
        let oldHz = currentPollHz
        installPollTimer()
        log("Poll rate live-updated: \(oldHz) Hz → \(currentPollHz) Hz")
    }

    /// Open the application the preset names, if any. Accepts a posix
    /// path ("/Applications/Steam.app") or a bundle identifier
    /// ("com.valvesoftware.steam"). Empty string = no-op. Optionally
    /// follows the path with `NSWorkspace.open(url:)` on a non-empty
    /// launchURL so a preset can deep-link to a specific game via a
    /// steam:// or itch:// scheme.
    private func applyPresetAutoLaunch(_ automation: PresetAutomation) {
        let trimmedApp = automation.launchAppPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedApp.isEmpty {
            let ws = NSWorkspace.shared
            if trimmedApp.hasPrefix("/") {
                let url = URL(fileURLWithPath: trimmedApp)
                ws.openApplication(at: url,
                                   configuration: NSWorkspace.OpenConfiguration(),
                                   completionHandler: nil)
            } else if let url = ws.urlForApplication(withBundleIdentifier: trimmedApp) {
                ws.openApplication(at: url,
                                   configuration: NSWorkspace.OpenConfiguration(),
                                   completionHandler: nil)
            } else {
                log("Preset auto-launch: couldn't resolve \(trimmedApp)")
            }
        }
        let trimmedURL = automation.launchURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty, let url = URL(string: trimmedURL) {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        StatsService.shared.engineStopped()
        engineGeneration &+= 1   // poison any in-flight macro/turbo blocks
        pollTimer?.invalidate()
        pollTimer = nil
        logFlushTimer?.invalidate()
        logFlushTimer = nil
        isRunning = false
        // Clear deferred state so a future start() with a different
        // preset doesn't see stale toggle / turbo / cache entries.
        toggleStates.removeAll()
        turboTimestamps.removeAll()
        macrosInFlight.removeAll()
        serializedKeyCache.removeAll()
        bindKeyCache.removeAll()
        externalEventSubscription?.cancel()
        externalEventSubscription = nil
        ExternalInputDeviceService.shared.stopMonitoring()
        externalKeysDown.removeAll()
        externalMouseButtonsDown.removeAll()
        externalMouseDX.removeAll()
        externalMouseDY.removeAll()
        externalScrollDX.removeAll()
        externalScrollDY.removeAll()
        driveProcessor.releaseAll()
        InputSimulator.shared.releaseAll()
        MIDIService.shared.releaseAllNotes()
        if usesTouchpadInput {
            TouchpadService.shared.release()
            usesTouchpadInput = false
        }
        if usesCursorRegionInput {
            CursorRegionService.shared.endTracking()
            usesCursorRegionInput = false
        }

        // Cursor-guard goes idle: re-show the cursor if we hid it,
        // stop the recenter timer. Order matters: clear the preset
        // override AFTER the engine flag flips so the service has a
        // chance to undo its own state with the override still
        // active, then we discard the override.
        CursorGuardService.shared.engineDidChangeState(running: false)
        CursorGuardService.shared.clearPresetOverride()

        // Drop the power-source watcher; matched against the retain
        // call in start() so SystemStatsService can park its timer
        // when nothing else is observing.
        powerSourceSubscription?.cancel()
        powerSourceSubscription = nil
        lastSeenPowerSource = nil
        SystemStatsService.shared.release()

        // Revert any preset light-bar override by re-asserting each
        // light-capable controller's stored slot color. setControllerLight
        // reads from `lightColors` / slot defaults, so the user-configured
        // general color comes back automatically.
        if let preset = activePreset, preset.lightBarColor != nil {
            for slot in controllerService.controllerDetails.keys
                where controllerService.controllerDetails[slot]?.hasLight == true {
                controllerService.setControllerLight(at: slot)
            }
            log("Reverted light bar to general color")
        }

        activeStates.removeAll()
        activeInputs.removeAll()
        activePreset = nil
        log("Engine stopped")
        // Final flush so the user sees the stop event in the log view.
        flushPendingLog()
    }

    // MARK: - Debug Logging

    private func log(_ message: String, joystick: Int? = nil) {
        debugLineCount += 1
        let entry = "[\(debugLineCount)] \(message)"
        // Write to the internal buffer (no @Published trigger). The flush
        // timer copies this into `debugLog` at 5 Hz so observers of the
        // mapping engine do not re-render on every input event.
        pendingLog.append((text: entry, joystickIndex: joystick))
        pendingLogDirty = true
        if pendingLog.count > 50 {
            pendingLog.removeFirst()
        }
        #if DEBUG
        print("[MappingEngine] \(message)")
        #endif
    }

    /// Copy accumulated log entries into the @Published `debugLog` array.
    /// Only fires when there's something new and only at the timer's rate.
    ///
    /// Hard cap at 500 lines on the published mirror. `pendingLog` is
    /// capped at 50 between flushes but `debugLog` accumulates across
    /// engine sessions - without the cap it would grow unbounded as
    /// the user activates / deactivates presets across a long session.
    private func flushPendingLog() {
        guard pendingLogDirty, !pendingLog.isEmpty else { return }
        pendingLogDirty = false
        debugLog = pendingLog
        if debugLog.count > 500 {
            debugLog.removeFirst(debugLog.count - 500)
        }
    }

    // MARK: - Polling

    private var pollCount = 0

    /// Accumulated mouse motion delta for the current poll frame. Each
    /// continuous axis binding adds to this, and a single CGEvent is
    /// posted at the end of the poll. This produces true diagonal motion
    /// when, for example, a stick is pushed up-and-left and two separate
    /// bindings (X+ and Y-) both fire in the same frame.
    // Mouse motion accumulates as Float so slow, sub-pixel stick deflections
    // are not truncated to zero every frame. The whole-pixel part is posted at
    // flush and the fractional remainder is carried into the next frame, so a
    // gentle, precise stick still moves the cursor smoothly (important for fine
    // pointer control and accessibility).
    private var pendingMouseDeltaX: Float = 0
    private var pendingMouseDeltaY: Float = 0
    private var mouseCarryX: Float = 0
    private var mouseCarryY: Float = 0

    /// One-stick drive-mode engine (build 18). Holds gear/PWM/gesture state
    /// across poll frames; fed from the active preset's driveConfig.
    private let driveProcessor = DriveModeProcessor()
    /// Per-frame cache of controller states read by the binding loop, reused
    /// by the drive block so it doesn't re-read (and re-derive) the same slot.
    private var lastSlotState: [Int: ControllerState] = [:]
    /// Throttled live mirror of drive telemetry for on-screen feedback.
    /// nil when drive mode is off / inactive.
    @Published var driveLiveState: DriveModeProcessor.LiveState?
    private var pendingScrollDeltaX: Int32 = 0
    private var pendingScrollDeltaY: Int32 = 0

    private func pollControllers() {
        guard let preset = activePreset else { return }
        pollCount += 1
        // Cumulative session counter for the Stats panel - cheap UInt64
        // increment, ignored when the panel isn't subscribed.
        SystemStatsService.shared.recordControllerPolls()
        pendingMouseDeltaX = 0
        pendingMouseDeltaY = 0
        pendingScrollDeltaX = 0
        pendingScrollDeltaY = 0

        // Hoist time-source reads out of the per-binding inner loop.
        // CACurrentMediaTime is a monotonic Double seconds counter with
        // no allocation cost; replaces the Date() that used to be
        // constructed per turbo binding per poll frame.
        let nowMonotonic = CACurrentMediaTime()
        // The raw-state log line and the published-active-inputs flush
        // also wanted a Date(), but they only fire infrequently so we
        // build one lazily inside those branches.
        let shouldLogRawState = (pollCount % 120 == 1)

        lastSlotState.removeAll(keepingCapacity: true)
        for (joystickIndex, joystickMapping) in preset.joysticks.enumerated() {
            // External-only bindings can fire even without a controller, so
            // we don't bail out when the slot is empty - we just skip the
            // controller-side checks for that binding.
            let state = controllerService.readControllerState(at: joystickIndex)
            if let state { lastSlotState[joystickIndex] = state }

            // Log raw state once per second for debugging. The .filter +
            // .map + String(format:) chain allocates several arrays per
            // call - now gated behind both the 1Hz cadence AND the
            // debugEnabled flag so it's free when the user has the
            // panel collapsed.
            if shouldLogRawState && debugEnabled, let state = state {
                let activeButtons = state.buttons.filter { $0.value > 0.5 }.map { "btn\($0.key)" }
                let activeAxes = state.axes.filter { abs($0.value) > defaultAxisThreshold }.map { "axi\($0.key)=\(String(format: "%.2f", $0.value))" }
                if !activeButtons.isEmpty || !activeAxes.isEmpty {
                    log("Raw state J\(joystickIndex): \(activeButtons + activeAxes)", joystick: joystickIndex)
                }
            }

            // Reuse the scratch set instead of allocating a fresh
            // Set<String> every joystick every poll frame.
            scratchActiveSet.removeAll(keepingCapacity: true)

            for binding in joystickMapping.bindings {
                let isActive: Bool
                if binding.input.type == .extKey || binding.input.type == .extMouse {
                    isActive = checkExternalInput(binding.input)
                } else if let s = state {
                    isActive = checkInput(binding.input, state: s, binding: binding)
                } else {
                    // Controller binding but the slot is empty - can't fire.
                    isActive = false
                }
                let inputKey = cachedKey(for: binding)
                // bindKey is keyed by binding UUID so two distinct
                // bindings on the same physical input (e.g. one toggle,
                // one turbo, or two different macros) don't share
                // toggleStates / turboTimestamps entries. Previously
                // bindKey was "\(joystickIndex):\(inputKey)" which
                // collided when the user added a second binding on
                // the same input. Only the toggle / turbo / macro paths read
                // it, so build it lazily: a plain binding must not allocate
                // binding.id.uuidString on every 120 Hz poll frame.
                let bindKey: String
                if binding.toggleMode == true
                    || binding.turboEnabled == true
                    || binding.macroSteps != nil {
                    if let cached = bindKeyCache[binding.id] {
                        bindKey = cached
                    } else {
                        let k = "\(joystickIndex):\(binding.id.uuidString)"
                        bindKeyCache[binding.id] = k
                        bindKey = k
                    }
                } else {
                    bindKey = ""
                }

                if isActive {
                    scratchActiveSet.insert(inputKey)
                }

                let wasActive = activeStates[joystickIndex]?.contains(inputKey) ?? false
                // Axis-driven MIDI CC / pitch-bend must never fire on the press
                // or release edge - that spikes the value for one frame and
                // slams it on release. fireOutputs suppresses those two output
                // types when this is true; the continuous path handles them.
                let inputIsAxis = binding.input.type == .axis

                if binding.toggleMode == true {
                    // Toggle mode: press toggles on/off
                    if isActive && !wasActive {
                        let isToggledOn = toggleStates[bindKey] ?? false
                        if isToggledOn {
                            if debugEnabled { log("TOGGLE OFF: \(inputKey)", joystick: joystickIndex) }
                            fireOutputs(binding.outputs, press: false, inputIsAxis: inputIsAxis)
                            toggleStates[bindKey] = false
                        } else {
                            if debugEnabled {
                                log("TOGGLE ON: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                            }
                            // A macro binding with Toggle enabled fires its
                            // chain on the ON transition. The toggle branch
                            // used to consult only binding.outputs, so the
                            // documented "Toggle + Macro" combination
                            // silently did nothing.
                            if let steps = binding.macroSteps, !steps.isEmpty {
                                if !macrosInFlight.contains(bindKey) {
                                    macrosInFlight.insert(bindKey)
                                    macroCancelRequests.remove(bindKey)
                                    executeMacro(steps, joystickIndex: joystickIndex, bindKey: bindKey,
                                                 repeatCount: binding.repeatCount ?? 1)
                                }
                            } else {
                                fireOutputs(binding.outputs, press: true, inputIsAxis: inputIsAxis)
                            }
                            toggleStates[bindKey] = true
                            fireFeedback(for: binding, joystickIndex: joystickIndex)
                        }
                    }
                    // Keep firing continuous outputs while toggled on
                    if toggleStates[bindKey] == true, let s = state {
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                    }
                } else if binding.turboEnabled == true {
                    // Turbo mode: rapid fire while held
                    if isActive {
                        if !wasActive {
                            if debugEnabled {
                                log("TURBO START: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                            }
                            fireFeedback(for: binding, joystickIndex: joystickIndex)
                        }
                        // Clamp turbo rate to a sane range so a zero or
                        // negative value (from a malformed preset) can't
                        // produce a +Infinity interval that disables
                        // turbo entirely. 1 Hz floor / 60 Hz ceiling.
                        let rate = max(1, min(60, binding.turboRate ?? 10))
                        let interval = 1.0 / Double(rate)
                        let lastFire = turboTimestamps[bindKey] ?? -.infinity
                        if nowMonotonic - lastFire >= interval {
                            fireOutputs(binding.outputs, press: true, inputIsAxis: inputIsAxis)
                            // Schedule release after ~40% of the interval.
                            // Capture engineGeneration so a stop() between
                            // press and release skips the release fire on
                            // a poisoned engine (avoids stuck keys when
                            // the user deactivates the preset mid-turbo).
                            let gen = engineGeneration
                            let outputs = binding.outputs
                            let axisFlag = inputIsAxis
                            DispatchQueue.main.asyncAfter(deadline: .now() + interval * 0.4) { [weak self] in
                                guard let self = self, self.engineGeneration == gen else { return }
                                self.fireOutputs(outputs, press: false, inputIsAxis: axisFlag)
                            }
                            turboTimestamps[bindKey] = nowMonotonic
                        }
                        if let s = state {
                            fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                        }
                    } else if wasActive {
                        log("TURBO END: \(inputKey)", joystick: joystickIndex)
                        fireOutputs(binding.outputs, press: false, inputIsAxis: inputIsAxis)
                        turboTimestamps.removeValue(forKey: bindKey)
                    }
                } else {
                    // Normal mode
                    let usesDeferred = binding.macroSteps == nil
                        && (binding.holdOutputs != nil || binding.doubleTapOutputs != nil)
                    if isActive && !wasActive {
                        StatsService.shared.recordButtonPress(inputKey: inputKey)
                        if debugEnabled {
                            log("PRESS: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                        }
                        // Check for macro. Guard against a re-press
                        // while the previous macro chain is still in
                        // flight - previously this kicked off a fresh
                        // executeMacro on every press transition,
                        // running the chain twice in parallel and
                        // duplicating every output event. Now the
                        // second press is ignored until the first
                        // chain finishes (it bumps macrosInFlight).
                        if let steps = binding.macroSteps, !steps.isEmpty {
                            if !macrosInFlight.contains(bindKey) {
                                macrosInFlight.insert(bindKey)
                                macroCancelRequests.remove(bindKey)
                                executeMacro(steps, joystickIndex: joystickIndex, bindKey: bindKey,
                                             repeatCount: binding.repeatCount ?? 1)
                            }
                        } else if usesDeferred {
                            // Tap-vs-hold / double-tap: record the press and
                            // defer the decision to the hold threshold check
                            // below or the release handler.
                            deferredPressStart[bindKey] = nowMonotonic
                        } else if (binding.repeatCount ?? 1) > 1 {
                            fireWithRepeat(binding)
                        } else {
                            fireOutputs(binding.outputs, press: true, inputIsAxis: inputIsAxis)
                        }
                        fireFeedback(for: binding, joystickIndex: joystickIndex)
                    } else if isActive, usesDeferred,
                              !holdFired.contains(bindKey),
                              let hold = binding.holdOutputs,
                              let start = deferredPressStart[bindKey],
                              nowMonotonic - start >= Double(max(50, min(5000, binding.holdThresholdMs ?? 300))) / 1000.0 {
                        // Held past the threshold: this press is the HOLD
                        // action. It stays pressed until the input releases.
                        holdFired.insert(bindKey)
                        if debugEnabled { log("HOLD: \(inputKey)", joystick: joystickIndex) }
                        fireOutputs(hold, press: true, inputIsAxis: inputIsAxis)
                    } else if !isActive && wasActive {
                        if debugEnabled { log("RELEASE: \(inputKey)", joystick: joystickIndex) }
                        if usesDeferred {
                            handleDeferredRelease(binding, bindKey: bindKey, now: nowMonotonic)
                        } else if binding.macroSteps == nil && (binding.repeatCount ?? 1) <= 1 {
                            fireOutputs(binding.outputs, press: false, inputIsAxis: inputIsAxis)
                        }
                        // Stop-on-release: letting go asks the running chain
                        // to halt at its next press hop and release held steps.
                        if binding.macroSteps != nil,
                           binding.macroInterruptOnRelease == true,
                           macrosInFlight.contains(bindKey) {
                            macroCancelRequests.insert(bindKey)
                        }
                    } else if isActive, !usesDeferred, let s = state {
                        // Deferred bindings skip continuous firing: which
                        // action this press means is not decided yet.
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                    }
                }
            }

            // Copy out into activeStates (cheap Set copy) so the
            // scratch can be reused next iteration.
            activeStates[joystickIndex] = scratchActiveSet
        }

        // One-stick drive mode (build 18). Runs after the binding loops so
        // its analog steering rides the same per-frame mouse flush below.
        // Releases every held key whenever drive is off or outputs pause.
        if let drive = preset.driveConfig, drive.enabled, !outputsPaused {
            // Reuse the slot state already read by the binding loop when the
            // drive slot is one of the polled joysticks; only read again if the
            // drive slot sits outside that range.
            let dstate = (drive.slot < preset.joysticks.count)
                ? lastSlotState[drive.slot]
                : controllerService.readControllerState(at: drive.slot)
            let ax = dstate?.axes[drive.steerAxis] ?? 0
            let ay = dstate?.axes[drive.throttleAxis] ?? 0
            pendingMouseDeltaX += driveProcessor.process(drive, axisX: ax, axisY: ay, now: nowMonotonic)
            // Publish live telemetry at ~15 Hz so the editor's drive readout
            // can show gear / throttle without churning the UI at 120 Hz.
            if pollCount % 8 == 0 {
                let s = driveProcessor.liveState
                if driveLiveState != s { driveLiveState = s }
            }
        } else {
            driveProcessor.releaseAll()
            if driveLiveState != nil { driveLiveState = nil }
        }

        // Flush accumulated mouse and scroll deltas as a single CGEvent.
        // Skipped while outputsPaused so the editor can stay open over an
        // active touchpad-mouse preset without the cursor flying around.
        // (Deltas themselves are zeroed at the start of every frame.)
        if !outputsPaused {
            // Convert the Float accumulator to whole pixels and carry the
            // fractional remainder into the next frame so slow motion is smooth.
            let totalX = pendingMouseDeltaX + mouseCarryX
            let totalY = pendingMouseDeltaY + mouseCarryY
            // Clamp before Int(): a malformed / imported preset with an absurd
            // speed could push the accumulator past Int range (a hard trap) or
            // to NaN. Normal deltas are a few pixels, far below this budget.
            let clampedX = totalX.isFinite ? max(-100_000, min(100_000, totalX)) : 0
            let clampedY = totalY.isFinite ? max(-100_000, min(100_000, totalY)) : 0
            let wholeX = Int(clampedX)
            let wholeY = Int(clampedY)
            mouseCarryX = clampedX - Float(wholeX)
            mouseCarryY = clampedY - Float(wholeY)
            if wholeX != 0 || wholeY != 0 {
                InputSimulator.shared.moveMouse(deltaX: wholeX, deltaY: wholeY)
                StatsService.shared.recordMouseMotion(pixels: abs(wholeX) + abs(wholeY))
            }
            if pendingScrollDeltaX != 0 || pendingScrollDeltaY != 0 {
                InputSimulator.shared.scrollWheel(deltaX: pendingScrollDeltaX, deltaY: pendingScrollDeltaY)
                StatsService.shared.recordScroll(ticks: Int(abs(pendingScrollDeltaX) + abs(pendingScrollDeltaY)))
            }
        }

        // Drain the touchpad per-frame deltas exactly once, after every binding
        // has read them via peekDelta. This lets two bindings on the same finger
        // and axis both see the motion (the old consumeDelta zeroed it on the
        // first read, so the second got 0). Unconditional so deltas can't pile
        // up and fling the cursor when outputs resume after a pause.
        TouchpadService.shared.endFrame()

        // Update active inputs for UI highlighting. Reuse the scratch
        // set so the union doesn't allocate a fresh container every
        // poll frame.
        scratchAllActiveSet.removeAll(keepingCapacity: true)
        for (_, states) in activeStates {
            scratchAllActiveSet.formUnion(states)
        }
        if scratchAllActiveSet != activeInputs {
            activeInputs = scratchAllActiveSet
        }
        // Mirror to the @Published copy at most 10 Hz so the highlighted row in
        // the editor doesn't trigger a full sheet re-render on every poll frame.
        // This is a trailing reconcile, not gated on a change this frame, so a
        // change that was throttled out still converges within ~0.1s instead of
        // leaving the published mirror permanently stale. Uses the monotonic
        // clock already captured at the top of pollControllers.
        if activeInputsPublished != activeInputs,
           nowMonotonic - activeInputsLastFlush > 0.1 {
            activeInputsLastFlush = nowMonotonic
            activeInputsPublished = activeInputs
        }

        // Drain external motion / scroll deltas now that bindings have read
        // them. Buttons and held keys stay sticky until released.
        externalMouseDX.removeAll(keepingCapacity: true)
        externalMouseDY.removeAll(keepingCapacity: true)
        externalScrollDX.removeAll(keepingCapacity: true)
        externalScrollDY.removeAll(keepingCapacity: true)
    }

    /// Returns cached serialized key for a binding's input to avoid string allocations in 120Hz loop
    private func cachedKey(for binding: BindingModel) -> String {
        if let cached = serializedKeyCache[binding.id] { return cached }
        let key = binding.input.serialized
        serializedKeyCache[binding.id] = key
        return key
    }

    /// Remap a raw axis magnitude (0...1) through the binding's inner and
    /// outer deadzones. Below the inner deadzone the result is 0. Above the
    /// outer deadzone the result is 1. Between them the value is linearly
    /// scaled so the full 0...1 output range is reached without having to
    /// push the stick to the absolute mechanical limit.
    private func remapMagnitude(_ magnitude: Float, binding: BindingModel?) -> Float {
        let inner = binding?.deadzone ?? defaultAxisThreshold
        let outer = binding?.outerDeadzone ?? 1.0
        let safeOuter = max(min(outer, 1.0), inner + 0.01)  // never collapse the range
        let m = max(0, min(1, magnitude))
        if m <= inner { return 0 }
        if m >= safeOuter { return 1 }
        return (m - inner) / (safeOuter - inner)
    }

    // MARK: - External Input Ingestion

    /// Routes one event from `ExternalInputDeviceService` into the parallel
    /// state maps. Called on main, so no locking is needed - the 120 Hz
    /// poll loop reads the same maps from the same actor.
    /// Latest Force Touch pressure (0-1) and click stage from the Mac
    /// trackpad, fed by pressureChanged events while external-input
    /// monitoring runs.
    private var externalPressure: Float = 0
    private var externalPressureStage: Int = 0

    private func ingestExternalEvent(_ event: ExternalInputDeviceService.Event) {
        switch event {
        case .keyDown(let dev, let code):
            var s = externalKeysDown[dev] ?? []
            s.insert(code)
            externalKeysDown[dev] = s
        case .keyUp(let dev, let code):
            var s = externalKeysDown[dev] ?? []
            s.remove(code)
            externalKeysDown[dev] = s
        case .mouseButtonDown(let dev, let btn):
            var s = externalMouseButtonsDown[dev] ?? []
            s.insert(btn)
            externalMouseButtonsDown[dev] = s
        case .mouseButtonUp(let dev, let btn):
            var s = externalMouseButtonsDown[dev] ?? []
            s.remove(btn)
            externalMouseButtonsDown[dev] = s
        case .mouseMove(let dev, let dx, let dy):
            externalMouseDX[dev] = (externalMouseDX[dev] ?? 0) + dx
            externalMouseDY[dev] = (externalMouseDY[dev] ?? 0) + dy
        case .scroll(let dev, let dx, let dy):
            externalScrollDX[dev] = (externalScrollDX[dev] ?? 0) + dx
            externalScrollDY[dev] = (externalScrollDY[dev] ?? 0) + dy
        case .pressureChanged(_, let value, let stage):
            externalPressure = value
            externalPressureStage = stage
        }
    }

    /// Evaluates an external `.extKey` or `.extMouse` input against the
    /// parallel state maps. `nil` device ID matches any device - useful
    /// for bindings the user wants to fire from "any keyboard".
    private func checkExternalInput(_ input: InputEvent) -> Bool {
        switch input.type {
        case .extKey:
            let hidCode = input.index
            if let dev = input.extDeviceID {
                return externalKeysDown[dev]?.contains(hidCode) ?? false
            }
            for (_, set) in externalKeysDown where set.contains(hidCode) {
                return true
            }
            return false
        case .extMouse:
            switch input.extMouseKind ?? .button {
            case .button:
                let btn = input.index
                if let dev = input.extDeviceID {
                    return externalMouseButtonsDown[dev]?.contains(btn) ?? false
                }
                for (_, set) in externalMouseButtonsDown where set.contains(btn) {
                    return true
                }
                return false
            case .pressure:
                // Analog Force Touch press as a threshold input. 0.25 sits
                // just under the force of a normal click, so a deliberate
                // light press fires without requiring the full click.
                return externalPressure >= 0.25
            case .deepPress:
                return externalPressureStage >= 2
            case .moveX, .moveY, .scrollX, .scrollY:
                // Half-axis style: positive direction means delta > 0, etc.
                // Threshold is 1 because HID deltas come through as integer
                // ticks that can be very small per frame.
                let delta: Int
                switch input.extMouseKind {
                case .moveX:
                    delta = input.extDeviceID.flatMap { externalMouseDX[$0] }
                        ?? externalMouseDX.values.reduce(0, +)
                case .moveY:
                    delta = input.extDeviceID.flatMap { externalMouseDY[$0] }
                        ?? externalMouseDY.values.reduce(0, +)
                case .scrollX:
                    delta = input.extDeviceID.flatMap { externalScrollDX[$0] }
                        ?? externalScrollDX.values.reduce(0, +)
                case .scrollY:
                    delta = input.extDeviceID.flatMap { externalScrollDY[$0] }
                        ?? externalScrollDY.values.reduce(0, +)
                default:
                    delta = 0
                }
                switch input.axisDirection {
                case .positive: return delta > 0
                case .negative: return delta < 0
                case .none:     return delta != 0
                }
            }
        default:
            return false
        }
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
            // Inclusive (>=) comparisons so an exact-edge value of 0.5
            // counts as pressed. Many d-pads quantise to {-1, 0, +1};
            // the > variant was correct for those but missed analog
            // d-pads that report exactly the threshold value on a
            // slow-press transition.
            switch input.hatDirection {
            case .up:
                return hat.y >= hatThreshold
            case .down:
                return hat.y <= -hatThreshold
            case .left:
                return hat.x <= -hatThreshold
            case .right:
                return hat.x >= hatThreshold
            case .none:
                return false
            }

        case .touchpad:
            // A touchpad "axis" is considered active while the finger is in
            // contact AND there is non-trivial motion in the requested
            // direction since the last poll. Motion driven outputs read the
            // delta directly via processAxisInput.
            let finger = input.touchpadFinger ?? input.index
            guard TouchpadService.shared.isFingerActive(finger),
                  let axis = input.touchpadAxis else { return false }
            // Peek without consuming so the continuous-output pass
            // later in the same poll frame still sees the delta. The
            // old code called consumeDelta here, zeroing the
            // accumulator, which broke analog touchpad-to-mouse
            // bindings (they fired once on swipe entry, then nothing).
            let value = TouchpadService.shared.peekDelta(finger: finger, axis: axis)
            switch input.axisDirection {
            case .positive: return value > axisThreshold
            case .negative: return value < -axisThreshold
            case .none:     return abs(value) > axisThreshold
            }

        case .touchpadRegion:
            // Press for as long as any finger sits inside the named region.
            guard let id = input.touchpadRegionID else { return false }
            return TouchpadService.shared.isRegionPressed(id)

        case .cursorRegion:
            // Mac-trackpad / mouse analogue of `.touchpadRegion`: press
            // while the cursor sits inside a user-defined screen rect.
            // Position is fed continuously by ExternalInputDeviceService's
            // CGEventTap as the cursor moves.
            guard let id = input.cursorRegionID else { return false }
            return CursorRegionService.shared.isRegionPressed(id)

        case .stickRegion:
            // Joystick stick analogue of `.touchpadRegion`: press
            // while the stick at input.index (0 = left, 1 = right)
            // is deflected into the named region. We respect the
            // binding's deadzone (so resting drift can't fire a
            // center region) and invertAxis (so a flipped-stick
            // binding sees the region in the same logical orientation
            // the user drew it).
            guard let id = input.stickRegionID else { return false }
            // Pull the two axes for the requested stick.
            let xAxisIdx = input.index == 1 ? 2 : 0
            let yAxisIdx = input.index == 1 ? 3 : 1
            var xRaw = state.axes[xAxisIdx] ?? 0
            var yRaw = state.axes[yAxisIdx] ?? 0
            // Deadzone gate: if the stick magnitude is below the
            // threshold, no region fires - prevents drift-driven
            // false positives.
            if hypot(xRaw, yRaw) < axisThreshold { return false }
            if binding?.invertAxis == true {
                xRaw = -xRaw
                yRaw = -yRaw
            }
            // Pass the corrected values directly. Re-packing them into a
            // cloned axes dict copied the slot's whole dictionary every
            // deflected frame just to override these two entries.
            return StickRegionService.shared.isRegionPressed(id, x: xRaw, y: yRaw)

        case .touchpadGesture:
            // Touchpad gestures (two-finger tap, etc.) are edge-fire:
            // TouchpadService sets a one-shot flag when it detects the
            // gesture; consumeGesture returns true exactly once and
            // resets. The MappingEngine treats that single-frame pulse
            // as a press + release, which fires whatever output the
            // user bound. Multiple bindings on the same gesture all
            // see the flag inside this poll frame because consume only
            // resets once they've all read true once - no, wait:
            // consume clears immediately. If two bindings reference
            // the same gesture, only one fires. That's intended:
            // stack bindings live in the SAME row's outputs[], not
            // separate rows.
            guard let kind = input.touchpadGestureKind else { return false }
            return TouchpadService.shared.consumeGesture(kind)

        case .motion:
            // Motion is treated as a half-axis: pick the channel and
            // direction the binding asked for, threshold on a small dead
            // zone so resting drift doesn't fire the binding.
            guard let channel = input.motionChannel,
                  let raw = state.motion[channel] else { return false }
            let value = (binding?.invertAxis == true) ? -raw : raw
            switch input.axisDirection {
            case .positive: return value > axisThreshold
            case .negative: return value < -axisThreshold
            case .none:     return abs(value) > axisThreshold
            }

        case .extKey, .extMouse:
            // Routed through `checkExternalInput` instead; this branch is
            // only reachable from legacy code paths that don't expect
            // external types.
            return checkExternalInput(input)
        }
    }

    // MARK: - Output Firing

    private func fireOutputs(_ outputs: [OutputAction], press: Bool, inputIsAxis: Bool = false) {
        // App actions run even while outputs are paused; otherwise a
        // controller-bound Pause / Resume binding could pause the engine and
        // never resume it. Hopped to main async because activating a preset
        // restarts the engine, which must not happen mid-poll.
        if press {
            for output in outputs where output.type == .appAction {
                let kind = output.appActionKind ?? .togglePauseOutputs
                let target = output.targetPresetID
                DispatchQueue.main.async {
                    MenuBarController.shared.performAppAction(kind, targetPresetID: target)
                }
            }
        }
        if outputsPaused { return }
        if press {
            for output in outputs {
                switch output.type {
                case .key: StatsService.shared.recordKeyPress()
                case .mouseButton: StatsService.shared.recordMouseClick()
                case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport:
                    StatsService.shared.recordMidiEvent()
                default: break
                }
            }
        }
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

            case .typeText:
                // Fire on press only; there is nothing to release.
                if press, let text = output.text, !text.isEmpty {
                    InputSimulator.shared.typeString(text)
                }

            case .appAction:
                // Dispatched above, before the pause gate.
                break

            case .mouseMotion, .mouseWheel:
                break

            case .midiNote:
                let note = output.midiNote ?? 60
                let vel = output.midiVelocity ?? 100
                let ch = output.midiChannel ?? 1
                if press {
                    MIDIService.shared.sendNoteOn(note: note, velocity: vel, channel: ch)
                } else {
                    MIDIService.shared.sendNoteOff(note: note, channel: ch)
                }

            case .midiCC:
                // Axis-driven CC is continuous: fireContinuousOutputs sends the
                // smoothly-scaled value every active frame. Firing on the edge
                // for an axis would spike the CC to the fixed value (127) for
                // one frame on every deadzone entry and slam it to 0 on
                // release, the same reason .mouseMotion/.mouseWheel break above.
                // Buttons still fire the configured value on press, 0 on release.
                if inputIsAxis { break }
                let cc = output.midiCCNumber ?? 1
                let ch = output.midiChannel ?? 1
                let value = press ? (output.midiCCValue ?? 127) : 0
                MIDIService.shared.sendCC(controller: cc, value: value, channel: ch)

            case .midiPitchBend:
                // Same as .midiCC: axes ride the continuous path; only buttons
                // snap to full bend on press and recenter on release.
                if inputIsAxis { break }
                let ch = output.midiChannel ?? 1
                let value = press ? 16383 : 8192
                MIDIService.shared.sendPitchBend(value: value, channel: ch)

            case .midiProgramChange:
                // Program Change fires only on press. There's no "release"
                // for a program change - the instrument stays on the new
                // patch until something else changes it.
                if press {
                    let prog = output.midiProgramNumber ?? 0
                    let ch = output.midiChannel ?? 1
                    MIDIService.shared.sendProgramChange(program: prog, channel: ch)
                }

            case .midiTransport:
                // Transport messages fire on press only. Stop is symmetric
                // with Start in user terms - assign both to different buttons.
                if press {
                    MIDIService.shared.sendTransport(output.midiTransport ?? .start)
                }
            }
        }
    }

    /// Execute a macro sequence asynchronously.
    ///
    /// Captures `engineGeneration` at schedule time. Each fireOutputs
    /// hop to main re-checks the captured value and bails immediately
    /// when they differ - i.e. the engine was stopped or restarted
    /// mid-macro. Without this guard a long macro (30 steps × 200 ms)
    /// keeps firing keyDown / keyUp events for minutes after the user
    /// deactivates the preset, leaving stuck synthesized keys.
    ///
    /// Step delays and holds are clamped to 30 s each so a malformed
    /// or adversarial preset with delayMs / holdMs = Int.max can't
    /// park a background thread for billions of years.
    // MARK: - Tap-vs-hold / double-tap state

    /// Monotonic press time per deferred binding (one with holdOutputs or
    /// doubleTapOutputs), recorded on the press transition; the decision of
    /// WHICH action fires is deferred until the hold threshold or release.
    private var deferredPressStart: [String: TimeInterval] = [:]
    /// Deferred bindings whose hold action is currently pressed.
    private var holdFired: Set<String> = []
    /// Last tap-release time per double-tap binding, for window matching.
    private var lastTapTime: [String: TimeInterval] = [:]
    /// Incrementing token per binding that invalidates a scheduled
    /// single-tap fire when a second tap lands inside the window.
    private var pendingSingleTapToken: [String: Int] = [:]

    /// Resolve a tap-vs-hold / double-tap binding when its input releases.
    private func handleDeferredRelease(_ binding: BindingModel, bindKey: String, now: TimeInterval) {
        deferredPressStart.removeValue(forKey: bindKey)
        if holdFired.contains(bindKey) {
            // The hold action is down; release it.
            holdFired.remove(bindKey)
            fireOutputs(binding.holdOutputs ?? [], press: false)
            return
        }
        // Released before the hold threshold: this press is a tap.
        if binding.doubleTapOutputs != nil {
            let window = Double(max(100, min(2000, binding.doubleTapWindowMs ?? 300))) / 1000.0
            if let last = lastTapTime[bindKey], now - last <= window {
                // Second tap inside the window: the double action fires and
                // the pending single-tap is cancelled via the token bump.
                lastTapTime.removeValue(forKey: bindKey)
                pendingSingleTapToken[bindKey, default: 0] += 1
                pulse(binding.doubleTapOutputs ?? [])
            } else {
                // First tap: wait out the window before firing the single
                // action, in case a second tap arrives.
                lastTapTime[bindKey] = now
                let token = (pendingSingleTapToken[bindKey] ?? 0) + 1
                pendingSingleTapToken[bindKey] = token
                let gen = engineGeneration
                let outputs = binding.outputs
                DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
                    guard let self,
                          self.engineGeneration == gen,
                          self.pendingSingleTapToken[bindKey] == token,
                          self.lastTapTime[bindKey] != nil else { return }
                    self.lastTapTime.removeValue(forKey: bindKey)
                    self.pulse(outputs)
                }
            }
        } else {
            // Plain tap-vs-hold: the tap action fires as a quick pulse.
            pulse(binding.outputs)
        }
    }

    /// Fire outputs as a short press-then-release pulse. The release is
    /// generation-guarded like turbo's scheduled release, so a stop()
    /// between the two cannot leave a synthesized key down on a preset
    /// that has moved on (releaseAll in stop() covers the gap).
    private func pulse(_ outputs: [OutputAction]) {
        fireOutputs(outputs, press: true)
        let gen = engineGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.engineGeneration == gen else { return }
            self.fireOutputs(outputs, press: false)
        }
    }

    /// bindKeys whose running macro chain should stop at the next press hop.
    /// Set by the release transition when the binding opts into
    /// macroInterruptOnRelease; consumed (and cleared) by executeMacro.
    private var macroCancelRequests: Set<String> = []

    /// Ask a running chain to stop. Reads on the main actor only.
    func requestMacroCancel(bindKey: String) {
        macroCancelRequests.insert(bindKey)
    }

    private func executeMacro(_ steps: [MacroStep], joystickIndex: Int, bindKey: String,
                              repeatCount: Int = 1) {
        StatsService.shared.recordMacroExecution()
        log("MACRO: executing \(steps.count) steps", joystick: joystickIndex)
        let scheduledGen = engineGeneration
        let repeats = max(1, min(100, repeatCount))
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            // Set when a press hop observes a generation change (engine
            // stopped or preset switched): the rest of the chain exits
            // instead of sleeping out its full duration, and no further
            // releases fire for presses that never happened.
            var chainAbandoned = false
            // Actions pressed by .down steps that have not been released by a
            // matching .up step yet. Anything left when the chain ends (or is
            // abandoned) gets released so a chord can never stay stuck.
            var heldActions: [OutputAction] = []
            outer: for _ in 0..<repeats {
                for step in steps {
                    guard self != nil, !chainAbandoned else { break outer }
                    // Pre-step delay (clamped to 30s).
                    if step.delayMs > 0 {
                        let secs = min(Double(step.delayMs) / 1000.0, 30.0)
                        Thread.sleep(forTimeInterval: secs)
                    }
                    let kind = step.eventKind ?? .tap

                    // A Release step lets go of an earlier held action. The
                    // release fires regardless of generation (scoped, safe)
                    // and the step has no press/hold phase of its own.
                    if kind == .up {
                        DispatchQueue.main.async { [weak self] in
                            self?.fireOutputs([step.action], press: false)
                        }
                        let serialized = step.action.serialized
                        heldActions.removeAll { $0.serialized == serialized }
                        continue
                    }

                    // Press - guard generation and cancel requests on main
                    // where they are safe to read. The semaphore makes the
                    // press outcome visible to this thread (signal/wait
                    // orders the memory access) before the hold sleep starts;
                    // the box exists only to satisfy strict concurrency
                    // checking for that pattern.
                    let outcome = MacroPressOutcome()
                    let pressGate = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { [weak self] in
                        if let self,
                           self.engineGeneration == scheduledGen,
                           !self.macroCancelRequests.contains(bindKey) {
                            self.fireOutputs([step.action], press: true)
                            outcome.didPress = true
                        }
                        pressGate.signal()
                    }
                    pressGate.wait()
                    let didPress = outcome.didPress
                    // Hold (clamped to 30s).
                    if step.holdMs > 0 {
                        let secs = min(Double(step.holdMs) / 1000.0, 30.0)
                        Thread.sleep(forTimeInterval: secs)
                    }
                    if didPress {
                        if kind == .down {
                            // Stay held for the following steps (chords).
                            heldActions.append(step.action)
                        } else {
                            // Release ONLY this step's output, whether or not
                            // the generation still matches by now: a macro
                            // mid-hold that gets shut down by stop() must not
                            // leave a synthesized key permanently down. Scoped
                            // to the step, so a mid-macro preset switch cannot
                            // drop the NEXT preset's freshly-pressed keys the
                            // way a global releaseAll here once did.
                            DispatchQueue.main.async { [weak self] in
                                self?.fireOutputs([step.action], press: false)
                            }
                        }
                    } else {
                        // Press was skipped (generation changed or the user
                        // released with stop-on-release): firing the release
                        // anyway could drop an input the next preset is
                        // legitimately holding. Exit the chain.
                        chainAbandoned = true
                    }
                }
            }
            // Let go of anything a .down step left held, newest first, so an
            // abandoned or unbalanced chain cannot leave a chord stuck.
            if !heldActions.isEmpty {
                let leftovers = Array(heldActions.reversed())
                DispatchQueue.main.async { [weak self] in
                    for action in leftovers {
                        self?.fireOutputs([action], press: false)
                    }
                }
            }
            // Chain done or abandoned; clear the in-flight flag so the next
            // press can fire a fresh macro execution, and drop any unconsumed
            // cancel request so it cannot abort a future chain.
            DispatchQueue.main.async { [weak self] in
                self?.macrosInFlight.remove(bindKey)
                self?.macroCancelRequests.remove(bindKey)
            }
        }
    }

    /// Execute outputs with repeat count.
    ///
    /// Repeat count is clamped to 10 000 and delay to 30 s to bound the
    /// worst-case from an adversarial / malformed preset. Each fire
    /// hop checks `engineGeneration` against the value captured at
    /// schedule time so an active repeat won't leak past stop().
    private func fireWithRepeat(_ binding: BindingModel) {
        let rawCount = binding.repeatCount ?? 1
        let count = max(1, min(10_000, rawCount))
        let rawDelayMs = binding.repeatDelayMs ?? 100
        let delaySecs = min(Double(rawDelayMs) / 1000.0, 30.0)

        if count <= 1 {
            fireOutputs(binding.outputs, press: true)
            return
        }

        let scheduledGen = engineGeneration
        let outputs = binding.outputs
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for i in 0..<count {
                guard self != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.engineGeneration == scheduledGen else { return }
                    self.fireOutputs(outputs, press: true)
                }
                Thread.sleep(forTimeInterval: 0.05)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.engineGeneration == scheduledGen else { return }
                    self.fireOutputs(outputs, press: false)
                }
                if i < count - 1 {
                    Thread.sleep(forTimeInterval: delaySecs)
                }
            }
        }
    }

    private func fireContinuousOutputs(_ outputs: [OutputAction], input: InputEvent, state: ControllerState, binding: BindingModel? = nil) {
        if outputsPaused { return }
        for output in outputs {
            switch output.type {
            case .mouseMotion:
                guard let axis = output.mouseAxis, let dir = output.mouseDirection else { continue }
                let speed = output.speed ?? 6

                // Variable sensitivity defaults to true for axis input (gives natural feel).
                // When false, output fires at full speed once the axis crosses the deadzone.
                let useVariable = binding?.variableSensitivity ?? (input.type == .axis || input.type == .touchpad || input.type == .motion)

                var magnitude: Float = 1.0
                var signedMagnitude: Float = 1.0   // for touchpad / motion: sign indicates direction of motion
                if useVariable, input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
                    let rawMag = min(abs(axisValue), 1.0)
                    // Apply inner/outer deadzone remap before the curve so
                    // the curve operates on the post-deadzone normalized
                    // 0...1 range, not the raw analog value.
                    magnitude = remapMagnitude(rawMag, binding: binding)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                } else if input.type == .touchpad,
                          let tpAxis = input.touchpadAxis {
                    let finger = input.touchpadFinger ?? input.index
                    // Touchpad already reports a per-frame delta; we don't
                    // need to remap by a deadzone here. Sign carries motion
                    // direction. Use a much larger gain than axes because
                    // delta values are typically very small (a fraction of
                    // surface width per frame).
                    // peek, not consume: the per-frame delta is drained once at
                    // the end of pollControllers so multiple bindings on the
                    // same finger+axis all read the same motion.
                    var delta = TouchpadService.shared.peekDelta(finger: finger, axis: tpAxis)
                    if binding?.invertAxis == true { delta = -delta }
                    // Filter by requested half-axis: + means motion in the
                    // positive direction counts, motion in the other direction
                    // is ignored. This lets users bind "swipe right" → mouse
                    // right and "swipe left" → mouse left independently.
                    switch input.axisDirection {
                    case .positive: if delta < 0 { delta = 0 }
                    case .negative: if delta > 0 { delta = 0 }
                    case .none: break
                    }
                    // Touchpad speed multiplier - delta is in [-1, 1] roughly
                    // per second of motion; scale so a normal swipe moves the
                    // cursor a healthy distance.
                    let gain: Float = 80.0
                    signedMagnitude = delta * gain
                    magnitude = abs(signedMagnitude)
                }

                // Motion (gyro / accel) feeds the analog mouse path the same
                // way touchpad delta does. A positive gyro-Y while bound to
                // mouse-X+ moves the cursor right; the binding's invertAxis
                // flag flips the polarity.
                if useVariable, input.type == .motion,
                   let channel = input.motionChannel,
                   var motionValue = state.motion[channel] {
                    if binding?.invertAxis == true { motionValue = -motionValue }
                    // Filter by half-axis like we do for touchpad.
                    switch input.axisDirection {
                    case .positive: if motionValue < 0 { motionValue = 0 }
                    case .negative: if motionValue > 0 { motionValue = 0 }
                    case .none: break
                    }
                    // Gyro rotation rate is roughly radians/sec; tilt of a
                    // controller during normal gameplay produces values up
                    // to ~5 rad/s. Apply a moderate gain so a wrist twist
                    // gives a useful cursor delta.
                    let gain: Float = 8.0
                    signedMagnitude = motionValue * gain
                    magnitude = abs(signedMagnitude)
                }

                let scaledSpeed: Float
                if input.type == .touchpad || input.type == .motion {
                    // signedMagnitude already encodes direction + speed;
                    // mouseDirection picks which CGEvent axis it adds to.
                    // Guard against NaN/Inf: an uncalibrated DualSense
                    // can briefly publish NaN motion samples right
                    // after connect, and Float(.nan) accumulation would
                    // poison the carry.
                    let raw = abs(signedMagnitude) * Float(speed) / 6.0
                    scaledSpeed = raw.isFinite ? raw : 0
                } else {
                    let raw = Float(speed) * magnitude
                    scaledSpeed = raw.isFinite ? raw : 0
                }
                // Accumulate into pendingMouseDelta. The poll loop flushes
                // the total in a single CGEvent at the end of the frame so
                // diagonal motion combines naturally.
                switch (axis, dir) {
                case (.horizontal, .positive): pendingMouseDeltaX += scaledSpeed
                case (.horizontal, .negative): pendingMouseDeltaX -= scaledSpeed
                case (.vertical, .positive): pendingMouseDeltaY += scaledSpeed
                case (.vertical, .negative): pendingMouseDeltaY -= scaledSpeed
                }

            case .mouseWheel:
                guard let axis = output.mouseAxis, let dir = output.mouseDirection else { continue }
                let speed = output.speed ?? 6

                let useVariable = binding?.variableSensitivity ?? (input.type == .axis)

                var magnitude: Float = 1.0
                if useVariable, input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
                    let rawMag = min(abs(axisValue), 1.0)
                    magnitude = remapMagnitude(rawMag, binding: binding)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                }

                // Same NaN guard as the mouse-motion path above.
                let rawScroll = Float(speed) * magnitude
                // Clamp before Int32(): an absurd imported scroll speed would
                // otherwise trap even though isFinite is true.
                let scaledSpeed = rawScroll.isFinite
                    ? Int32(max(-1_000_000, min(1_000_000, rawScroll))) : 0
                switch (axis, dir) {
                case (.horizontal, .positive): pendingScrollDeltaX += scaledSpeed
                case (.horizontal, .negative): pendingScrollDeltaX -= scaledSpeed
                case (.vertical, .positive): pendingScrollDeltaY += scaledSpeed
                case (.vertical, .negative): pendingScrollDeltaY -= scaledSpeed
                }

            case .midiCC:
                // Continuous axis driving a CC. Map the axis's full range to
                // 0..127. For positive-only inputs (triggers, axis "positive"
                // direction) we map 0..1 to 0..127. For full-range axes we
                // map -1..1 to 0..127.
                guard input.type == .axis, var axisValue = state.axes[input.index] else { continue }
                if binding?.invertAxis == true { axisValue = -axisValue }

                let ccValue: Int
                if input.axisDirection == .positive {
                    var mag = max(0, min(1, axisValue))
                    if let curve = binding?.sensitivityCurve { mag = abs(curve.apply(mag)) }
                    ccValue = Int(mag * 127)
                } else if input.axisDirection == .negative {
                    var mag = max(0, min(1, -axisValue))
                    if let curve = binding?.sensitivityCurve { mag = abs(curve.apply(mag)) }
                    ccValue = Int(mag * 127)
                } else {
                    // Full-range axis: -1..1 maps to 0..127
                    let normalized = (axisValue + 1) / 2
                    ccValue = Int(max(0, min(1, normalized)) * 127)
                }
                let cc = output.midiCCNumber ?? 1
                let ch = output.midiChannel ?? 1
                MIDIService.shared.sendCC(controller: cc, value: ccValue, channel: ch)

            case .midiPitchBend:
                // Pitch bend is signed and centered at 8192. -1..1 maps to 0..16383.
                guard input.type == .axis, var axisValue = state.axes[input.index] else { continue }
                if binding?.invertAxis == true { axisValue = -axisValue }
                var v: Float
                if input.axisDirection == .positive {
                    v = max(0, min(1, axisValue))
                } else if input.axisDirection == .negative {
                    v = -max(0, min(1, -axisValue))
                } else {
                    v = max(-1, min(1, axisValue))
                }
                if let curve = binding?.sensitivityCurve {
                    let mag = curve.apply(abs(v))
                    v = v >= 0 ? mag : -mag
                }
                let pbValue = Int((v + 1) / 2 * 16383)
                let ch = output.midiChannel ?? 1
                MIDIService.shared.sendPitchBend(value: pbValue, channel: ch)

            default:
                break
            }
        }
    }

    // MARK: - Feedback (Haptics + Speech)

    /// Fire haptic and speech feedback for a binding press event.
    private func fireFeedback(for binding: BindingModel, joystickIndex: Int) {
        if outputsPaused { return }
        if binding.hapticEnabled == true,
           joystickIndex < controllerService.connectedControllers.count {
            let controller = controllerService.connectedControllers[joystickIndex]
            let intensity = binding.hapticIntensity ?? 0.6
            FeedbackService.shared.vibrate(controller: controller, intensity: intensity)
        }

        if binding.speechEnabled == true {
            let phrase = binding.speechText?.isEmpty == false
                ? binding.speechText!
                : binding.input.serialized
            let destination = binding.speechDestination ?? .mac
            FeedbackService.shared.speak(phrase, destination: destination)
        }
    }
}

/// Carries a macro step's press outcome from the main-queue hop back to the
/// macro's background thread. The DispatchSemaphore signal/wait pair in
/// executeMacro orders the write before the read; this box exists because
/// strict concurrency checking cannot see that ordering on a captured var.
private final class MacroPressOutcome: @unchecked Sendable {
    var didPress = false
}

/// Runtime engine for `DriveConfig`: converts one analog stick into a full
/// vehicle control scheme (steering + throttle/brake) with a Drive/Reverse
/// gear gesture. Holds the per-frame state (gear, PWM phase, pressed keys,
/// gesture history) so the MappingEngine poll loop stays clean. Throttle
/// keys are emitted through InputSimulator; steering-by-mouse is returned to
/// the caller so it can be merged into the engine's mouse-delta accumulator.
final class DriveModeProcessor {
    enum Gear { case drive, reverse }
    private(set) var gear: Gear = .drive

    /// Live telemetry for on-screen feedback, refreshed every process() call.
    struct LiveState: Equatable {
        var reverse = false
        var throttle: Float = 0   // 0-1 forward power being applied
        var brake: Float = 0      // 0-1 brake / backward
        var steer: Float = 0      // -1..1 after curve
    }
    private(set) var liveState = LiveState()

    private var pressed = Set<Int>()
    private var pwmTick: [Int: Int] = [:]
    private var backHits: [Double] = []
    private var wasAtBackWall = false

    /// Process one poll frame. Returns the steering mouse-X delta (pixels)
    /// to add to the engine's pending mouse delta; 0 when steering by keys.
    @discardableResult
    func process(_ cfg: DriveConfig, axisX: Float, axisY: Float, now: Double) -> Float {
        var x = axisX; if cfg.invertSteer { x = -x }
        var y = axisY; if cfg.invertThrottle { y = -y }
        let dz = Float(cfg.deadzone)
        let steer = deadzoned(x, dz)

        // Forward / backward throttle components. A trigger-style axis rests
        // at one end (no center, no backward): map its whole range to forward.
        let fwd: Float, back: Float
        if cfg.throttleIsTrigger {
            // Trigger axes normalize to 0...1 resting at 0 everywhere in this
            // app (GC buttonInput.value, HID byte/255, Steam byte/255), so use
            // the value directly. The old (y+1)/2 remap assumed a -1...1 trigger
            // and left the accelerator held at ~43% with the trigger released.
            fwd = max(0, deadzoned(y, dz))
            back = 0
        } else {
            fwd = max(0, deadzoned(y, dz))
            back = max(0, deadzoned(-y, dz))
        }

        // Gear / reverse gesture: count rising-edge "wall hits" at full back.
        // Disabled for trigger axes (they have no backward deflection).
        var shiftedToDriveThisFrame = false
        if cfg.reverseGestureEnabled && !cfg.throttleIsTrigger {
            let thr = Float(cfg.gestureThreshold)
            let atWall = back >= thr
            if atWall && !wasAtBackWall { backHits.append(now) }
            wasAtBackWall = atWall
            let window = Double(cfg.reverseWindowMs) / 1000.0
            backHits.removeAll { now - $0 > window }
            if gear == .drive && backHits.count >= max(1, cfg.reverseTapCount) {
                gear = .reverse; backHits.removeAll()
            }
            if gear == .reverse && fwd >= thr {   // full forward returns to Drive
                gear = .drive; backHits.removeAll()
                shiftedToDriveThisFrame = true
            }
        } else {
            gear = .drive
        }

        // Accumulate the desired duty per HID code so a code used by more than
        // one role (a shared steer/throttle key) is pulsed exactly ONCE with
        // its max duty, never double-advancing its PWM phase or fighting itself.
        var want: [Int: Float] = [:]
        func request(_ code: Int, _ d: Float) { if d > (want[code] ?? 0) { want[code] = d } }

        // Steering (with its own response curve, sign preserved).
        let steerShaped = signed(curve(abs(steer), Float(cfg.steerCurve)), steer)
        var steerMouseDX: Float = 0
        if cfg.steerMode == .mouse {
            steerMouseDX = steerShaped * Float(cfg.steerMouseSpeed)
        } else {
            request(cfg.steerLeftKey, steerShaped < 0 ? abs(steerShaped) : 0)
            request(cfg.steerRightKey, steerShaped > 0 ? abs(steerShaped) : 0)
        }

        // Throttle / brake by gear. PWM gives variable speed on a binary key:
        // duty scales with how far the stick is pushed. Skipped on the exact
        // frame the full-forward gesture shifts Reverse -> Drive so the stale
        // full-forward reading doesn't also slam the accelerator (no lurch).
        let exp = Float(cfg.throttleCurve)
        let cf = curve(fwd, exp)
        let cb = curve(back, exp)
        if !shiftedToDriveThisFrame {
            switch gear {
            case .drive:
                request(cfg.accelKey, cf)
                request(cfg.brakeKey, cb)
                // Active slow-down: when the stick is centered (no throttle,
                // no brake) hold a light brake so the vehicle decelerates
                // instead of coasting. `request` takes the max, so this never
                // fights a real throttle or brake input.
                if cfg.coastBrake && fwd <= 0.001 && back <= 0.001 {
                    request(cfg.brakeKey, Float(min(max(cfg.coastBrakeStrength, 0), 1)))
                }
            case .reverse:
                request(cfg.reverseKey, cf)
                request(cfg.brakeKey, cb)
            }
        }

        // Apply once per unique HID code this config can touch (unrequested
        // codes get duty 0 and are released).
        let codes: Set<Int> = [cfg.accelKey, cfg.brakeKey, cfg.reverseKey,
                               cfg.steerLeftKey, cfg.steerRightKey]
        for code in codes { pwm(code, want[code] ?? 0, cfg) }

        liveState = LiveState(reverse: gear == .reverse,
                              throttle: shiftedToDriveThisFrame ? 0 : cf,
                              brake: shiftedToDriveThisFrame ? 0 : cb,
                              steer: steerShaped)
        return steerMouseDX
    }

    /// Release every held key and clear gear/gesture state. Call when drive
    /// turns off, outputs pause, or the preset stops.
    func releaseAll() {
        for code in pressed { InputSimulator.shared.keyUp(code) }
        pressed.removeAll()
        pwmTick.removeAll()
        backHits.removeAll()
        wasAtBackWall = false
        gear = .drive
        liveState = LiveState()
    }

    // MARK: - Helpers

    private func deadzoned(_ v: Float, _ dz: Float) -> Float {
        let a = abs(v)
        if a <= dz { return 0 }
        let scaled = (a - dz) / max(0.0001, 1 - dz)
        return v < 0 ? -min(scaled, 1) : min(scaled, 1)
    }

    private func curve(_ v: Float, _ exp: Float) -> Float {
        guard v > 0 else { return 0 }
        return exp == 1 ? min(v, 1) : powf(min(v, 1), max(0.1, exp))
    }

    private func signed(_ mag: Float, _ ref: Float) -> Float { ref < 0 ? -mag : mag }

    private func setKey(_ code: Int, _ down: Bool) {
        let isDown = pressed.contains(code)
        if down && !isDown {
            InputSimulator.shared.keyDown(code); pressed.insert(code)
        } else if !down && isDown {
            InputSimulator.shared.keyUp(code); pressed.remove(code)
        }
    }

    /// Pulse a key on/off so its average hold time tracks `duty` (0-1).
    private func pwm(_ code: Int, _ duty: Float, _ cfg: DriveConfig) {
        if duty <= 0.02 { setKey(code, false); pwmTick[code] = 0; return }
        if duty >= 0.98 { setKey(code, true); return }
        let period = max(2, cfg.pwmPeriodTicks)
        // Clamp on-ticks to period-1 so any duty below the 0.98 cutoff keeps
        // at least one off-tick (no silent dead-band that reads as full hold).
        let onTicks = min(period - 1, max(1, Int((duty * Float(period)).rounded())))
        let t = (pwmTick[code] ?? 0) % period
        setKey(code, t < onTicks)
        pwmTick[code] = (t + 1) % period
    }
}
