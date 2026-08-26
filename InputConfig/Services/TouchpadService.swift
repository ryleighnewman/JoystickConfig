import Foundation
import QuartzCore   // CACurrentMediaTime() for allocation-free monotonic clock

/// Identifies which physical touchpad surface the calibration sheet is
/// operating on. The calibration sheet shows this in a picker at the top
/// so the user can explicitly pick the device they want to set up:
///
/// * **dualSense / dualShock4**: real per-finger touchpad on the controller.
///   Saves a `TouchpadCalibration` (finger min/max + grid) and stores
///   `TouchpadRegion`s in `TouchpadService`.
/// * **macTrackpad**: the MacBook built-in trackpad. macOS doesn't expose
///   per-finger coordinates to sandboxed apps, so this mode falls back to
///   *cursor* zones: regions are stored in `CursorRegionService` and a
///   `.cursorRegion` binding fires when the system cursor is inside.
enum TouchpadDevice: String, Codable, CaseIterable, Identifiable {
    case dualSense
    case dualShock4
    case macTrackpad

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dualSense:   return "DualSense"
        case .dualShock4:  return "DualShock 4"
        case .macTrackpad: return "Mac Trackpad"
        }
    }

    /// SF Symbol name shown next to the picker entry.
    var iconName: String {
        switch self {
        case .dualSense, .dualShock4: return "gamecontroller.fill"
        case .macTrackpad:            return "rectangle.and.hand.point.up.left.fill"
        }
    }

    /// True when the calibration sheet's finger-sweep flow applies. Mac
    /// trackpad bypasses the sweep because cursor coordinates are already
    /// in absolute screen space.
    var canFingerCalibrate: Bool { self != .macTrackpad }

    /// True when Quick Zero is meaningful. Mac trackpad has no origin to
    /// recenter, so the button is greyed out for it.
    var canQuickZero: Bool { self != .macTrackpad }

    /// True when this device's regions live in `CursorRegionService` (and
    /// produce `.cursorRegion` bindings) instead of `TouchpadService`.
    var usesCursorRegions: Bool { self == .macTrackpad }
}

/// Per-controller calibration. The user runs a calibration sweep once: as
/// they cover the surface, we record the min/max X/Y their finger actually
/// reaches. We then remap deltas so a "full sweep" of the calibrated area
/// equals one normalized unit, instead of using the nominal 1920×1080 box.
struct TouchpadCalibration: Codable, Hashable {
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int
    /// Wall-clock time the calibration was last persisted. nil for the
    /// sentinel uncalibrated value; non-nil whenever the user has saved.
    /// Decoded leniently - older saves without this key still load fine.
    var savedAt: Date?
    /// Flat-packed grid of "touched" cells from the calibration UI. Stored
    /// row-major (col + row * cols). Optional so older saves without this
    /// key still decode and produce an empty grid. The size in the file
    /// drives the on-screen layout; we ship 12×7 by default but the view
    /// is permissive about the dimensions it gets back.
    var gridCells: [Bool]?

    var spanX: Int { max(1, maxX - minX) }
    var spanY: Int { max(1, maxY - minY) }

    /// Sentinel "not yet calibrated" value covering the full nominal range
    /// of a DualSense / DualShock touchpad.
    static let uncalibrated = TouchpadCalibration(minX: 0, maxX: 1919, minY: 0, maxY: 1079, savedAt: nil, gridCells: nil)

    /// True when the user has actually done a calibration sweep (i.e. the
    /// stored bounds differ from the uncalibrated sentinel OR a savedAt was
    /// ever recorded).
    var isUserCalibrated: Bool {
        savedAt != nil ||
            !(minX == TouchpadCalibration.uncalibrated.minX
              && maxX == TouchpadCalibration.uncalibrated.maxX
              && minY == TouchpadCalibration.uncalibrated.minY
              && maxY == TouchpadCalibration.uncalibrated.maxY)
    }
}

/// A user-defined zone on the touchpad surface. Coordinates are normalized
/// 0...1 so they survive different controllers / calibration changes. When
/// a finger enters the region, the region becomes "pressed" and binding
/// inputs of type `.touchpadRegion` referencing this region fire as if a
/// button was pushed.
struct TouchpadRegion: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// Normalized rectangle. minX/maxX in [0, 1], same for Y. Y=0 is the
    /// top of the touchpad (matches the helper's coordinate convention).
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
    /// Color index (0..colorPalette.count-1) used for UI rendering. Each
    /// new region cycles through the palette so they're easy to tell apart.
    var colorIndex: Int

    /// Color palette regions cycle through. Kept in the model so it
    /// survives serialization and the UI doesn't need a separate lookup.
    static let colorPalette: [String] = ["mint", "cyan", "pink", "orange",
                                         "yellow", "purple", "indigo", "green"]

    init(id: UUID = UUID(), name: String, minX: Double, maxX: Double,
         minY: Double, maxY: Double, colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.minX = min(minX, maxX)
        self.maxX = max(minX, maxX)
        self.minY = min(minY, maxY)
        self.maxY = max(minY, maxY)
        self.colorIndex = colorIndex
    }

    /// Test whether the normalized point is inside this region.
    func contains(normalizedX: Double, y: Double) -> Bool {
        normalizedX >= minX && normalizedX <= maxX &&
        y >= minY && y <= maxY
    }
}

/// Bridges `TouchpadHelper` (a separate process that reads raw HID input
/// reports from DualSense / DualShock 4 controllers) into the rest of the
/// app. The main app cannot read those bytes directly without breaking
/// `gamecontrolleragentd`'s grip on the device, so we spawn the helper which
/// opens the HID device WITHOUT seizing, parses the touchpad bytes, and
/// emits them line-by-line on stdout.
///
/// `MappingEngine` pulls the latest per-finger delta out of `consumeDelta(...)`
/// each frame. The "consume" naming is deliberate: the call resets the
/// accumulator so a slow caller cannot accidentally double-count motion.
final class TouchpadService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = TouchpadService()

    /// Per-finger normalized delta-since-last-consume. Values are in roughly
    /// [-1, 1] but can exceed it on a fast swipe; consumers clamp.
    struct FingerDelta {
        var dx: Float = 0
        var dy: Float = 0
        var active: Bool = false
    }

    private let lock = NSLock()
    private var finger0Delta = FingerDelta()
    private var finger1Delta = FingerDelta()

    /// Most recent finger position keyed by (finger, contactId). Used to
    /// compute deltas. We track contactId so that finger-lift / finger-replace
    /// resets the baseline instead of producing a huge jump on touchdown.
    private var lastF0Pos: (id: UInt8, x: Int, y: Int)?
    private var lastF1Pos: (id: UInt8, x: Int, y: Int)?

    private var process: Process?
    private var pipeOut: Pipe?
    private var pipeIn: Pipe?
    private var pipeErr: Pipe?
    private var helperRunning = false

    /// Reference count: the helper subprocess stays alive while at least one
    /// caller has retained it. MappingEngine retains while a touchpad-using
    /// preset is active; the calibration UI retains while open.
    private var retainCount = 0

    /// Touchpad surface dimensions in helper-emitted native units. We use the
    /// larger DualSense bounds; DS4 reports slightly smaller Y, which still
    /// normalizes correctly since deltas are unit-divided.
    private let surfaceWidth: Float = 1920
    private let surfaceHeight: Float = 1080

    /// Currently active calibration. Loaded from UserDefaults at init; saved
    /// when the calibration view writes a new sweep.
    private var calibration: TouchpadCalibration = .uncalibrated
    private static let calibrationKey = "InputConfig.touchpadCalibration.v1"

    /// User-defined regions for tap-style mapping. Persisted alongside
    /// calibration so they survive app restarts.
    private var regions: [TouchpadRegion] = []
    private static let regionsKey = "InputConfig.touchpadRegions.v1"

    /// Region IDs currently being touched by any finger. Updated whenever a
    /// finger position changes; consumed by MappingEngine's checkInput.
    private var pressedRegions: Set<UUID> = []

    /// Latest absolute finger positions, used by the calibration view to
    /// paint touched cells. Reset on finger lift.
    private var currentF0: (x: Int, y: Int)?
    private var currentF1: (x: Int, y: Int)?

    /// Origin offset applied after the user hits Quick Zero. Subtracted
    /// from raw finger coordinates before any delta math or region
    /// matching. (0, 0) means no offset, which is the default.
    private var quickZeroOriginX: Int = 0
    private var quickZeroOriginY: Int = 0
    /// When the user last quick-zeroed; nil if never. Surfaced in the
    /// calibration sheet so the user can see whether a recenter is active.
    private var quickZeroAt: Date?

    /// Last device the calibration sheet was opened against. Stored in
    /// UserDefaults so the picker remembers the user's preference between
    /// sessions. Not used by the runtime pipeline; this is a UI hint only.
    private static let activeDeviceKey = "InputConfig.touchpadActiveDevice.v2"

    private init() {
        loadCalibration()
        loadRegions()
    }

    // MARK: - Lifecycle

    /// Increment the helper's retain count. Spawns the subprocess on the
    /// first retain. Pair every call with `release()`. Serialized under
    /// the same lock that guards the rest of the service state so two
    /// concurrent retainers can't both observe 0 and double-spawn.
    func retain() {
        lock.lock()
        retainCount += 1
        let shouldStart = (retainCount == 1)
        let count = retainCount
        lock.unlock()
        NSLog("[TouchpadService] retain (count=%d, willStart=%@)", count, shouldStart ? "yes" : "no")
        if shouldStart { start() }
    }

    /// Decrement the helper's retain count. Stops the subprocess when it
    /// drops to zero.
    func release() {
        lock.lock()
        retainCount = max(0, retainCount - 1)
        let shouldStop = (retainCount == 0)
        lock.unlock()
        if shouldStop { stop() }
    }

    /// Start the helper if not already running. Safe to call multiple times.
    ///
    /// On macOS 14+ the GameController framework already exposes
    /// DualSense / DualShock 4 touchpad coordinates via
    /// `touchpadPrimary` / `touchpadSecondary` on the typed gamepad
    /// subclass, and gamecontrollerd holds the HID device open
    /// exclusively. Spawning the helper in that scenario produces no
    /// data (its IOHIDDeviceOpen returns no input reports) and wastes
    /// a subprocess. We skip launch on those systems and rely on the
    /// framework feed installed by `GameControllerService.installTouchpadHandlers`.
    func start() {
        guard !helperRunning else { return }
        if #available(macOS 14.0, *) {
            // Skip the helper entirely; the GameController bridge is the
            // authoritative touch source on these systems, and the PS /
            // mute / DualSense Edge extras byte comes from the app's own
            // in-process HID reader (DualSenseSupplementService), which
            // receives both USB and Bluetooth input reports fine under
            // the sandbox - verified live with an Edge on BT.
            return
        }
        guard let helperURL = helperPath() else {
            NSLog("[TouchpadService] TouchpadHelper NOT FOUND in bundle. Touchpad input will not work.")
            return
        }

        NSLog("[TouchpadService] Launching helper from %@", helperURL.path)

        let p = Process()
        p.executableURL = helperURL

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        p.standardOutput = outPipe
        // Route stderr through a readability handler so the parent can
        // surface any launch / runtime error from the helper instead of
        // silently dropping it to /dev/null. Otherwise a sandbox kill,
        // HID-open failure, or matching-rule miss produces no observable
        // signal and the touchpad appears mysteriously broken.
        p.standardError = errPipe
        p.standardInput = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF: the helper closed its stdout. Detach so this handler doesn't
            // spin at 100% CPU re-firing on the closed descriptor (the same
            // pattern SteamControllerService guards against).
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consumeStdout(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    NSLog("[TouchpadHelper STDERR] %@", trimmed)
                }
            }
        }

        // If the helper exits unexpectedly, log the termination reason so
        // we can tell a deliberate stdin-close shutdown from a crash.
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason: String = (proc.terminationReason == .uncaughtSignal) ? "uncaughtSignal" : "exit"
            NSLog("[TouchpadService] Helper terminated (reason=%@ status=%d)", reason, status)
            // Only clear state if this is still the current helper, so a fast
            // restart can't have the old helper's late termination handler
            // clobber a newer live one.
            guard let self = self, self.process === proc else { return }
            self.helperRunning = false
            self.process = nil
        }

        do {
            try p.run()
            process = p
            pipeOut = outPipe
            pipeErr = errPipe
            pipeIn = inPipe
            helperRunning = true
            NSLog("[TouchpadService] Helper PID %d started", p.processIdentifier)
        } catch {
            NSLog("[TouchpadService] Helper launch FAILED: %@", error.localizedDescription)
        }
    }

    /// Stop the helper. Closes the stdin pipe; the helper exits when it
    /// observes that closure. Falls back to SIGTERM after a short grace.
    func stop() {
        guard helperRunning else { return }
        helperRunning = false

        pipeOut?.fileHandleForReading.readabilityHandler = nil
        // Clear the stderr handler too. Previously this was left
        // attached, which kept a strong reference to the closure (and
        // its capture of NSLog through self) until the file handle
        // was eventually GC'd. Detaching here makes shutdown clean.
        pipeErr?.fileHandleForReading.readabilityHandler = nil
        try? pipeIn?.fileHandleForWriting.close()

        if let p = process, p.isRunning {
            // Give it ~100ms to exit cleanly via stdin EOF, then terminate.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                if p.isRunning { p.terminate() }
            }
        }
        process = nil
        pipeOut = nil
        pipeErr = nil
        pipeIn = nil

        lock.lock()
        finger0Delta = FingerDelta()
        finger1Delta = FingerDelta()
        lastF0Pos = nil
        lastF1Pos = nil
        // Also clear gesture + region runtime state so a half-formed two-finger
        // tap or a still-pressed region can't carry over and fire under the next
        // preset after a stop / preset switch.
        currentF0 = nil
        currentF1 = nil
        pendingGesture = nil
        gestureFiredAt = nil
        twoFingerStartedAt = nil
        twoFingerMotionMagnitude = 0
        pressedRegions.removeAll()
        lock.unlock()
    }

    // MARK: - Consumer API (MappingEngine)

    /// Read & clear the accumulated delta for the given finger and axis.
    /// Returns a value normalized so `1.0` corresponds to one full sweep of
    /// the *calibrated* surface in a single frame.
    func consumeDelta(finger: Int, axis: TouchpadAxis) -> Float {
        lock.lock()
        defer { lock.unlock() }

        let key = finger == 1 ? 1 : 0
        var d = key == 0 ? finger0Delta : finger1Delta
        let value: Float
        switch axis {
        case .x:
            value = d.dx / Float(calibration.spanX)
            d.dx = 0
        case .y:
            value = d.dy / Float(calibration.spanY)
            d.dy = 0
        }
        if key == 0 { finger0Delta = d } else { finger1Delta = d }
        return value
    }

    /// Same value `consumeDelta` would return, but WITHOUT zeroing the
    /// accumulator. Lets the binding evaluator decide whether the
    /// binding is active without "spending" the delta the
    /// continuous-output pass will need to read in the same frame.
    /// Earlier code called `consumeDelta` for the activity check AND
    /// again for the analog output, which meant the second read saw 0
    /// and analog touchpad-to-mouse mappings only fired on entry.
    func peekDelta(finger: Int, axis: TouchpadAxis) -> Float {
        lock.lock()
        defer { lock.unlock() }
        let d = finger == 1 ? finger1Delta : finger0Delta
        switch axis {
        case .x: return d.dx / Float(calibration.spanX)
        case .y: return d.dy / Float(calibration.spanY)
        }
    }

    /// Drain the accumulated per-frame deltas after the mapping engine has read
    /// them via peekDelta. Called once at the end of every poll frame. Unlike
    /// consumeDelta, this lets multiple bindings on the same finger+axis read
    /// the same value within the frame, then clears the motion exactly once.
    /// Only dx/dy is cleared; finger-contact state is left intact.
    func endFrame() {
        lock.lock()
        finger0Delta.dx = 0
        finger0Delta.dy = 0
        finger1Delta.dx = 0
        finger1Delta.dy = 0
        lock.unlock()
    }

    /// True while the given finger is in contact with the touchpad.
    func isFingerActive(_ finger: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (finger == 1 ? finger1Delta : finger0Delta).active
    }

    /// Latest absolute (x, y) of the given finger in device-native units, or
    /// nil if the finger is not currently in contact. Used by the calibration
    /// view to draw a live cursor and to mark touched grid cells.
    func currentPosition(finger: Int) -> (x: Int, y: Int)? {
        lock.lock(); defer { lock.unlock() }
        return finger == 1 ? currentF1 : currentF0
    }

    /// Device-native touchpad bounds (DualSense values; DS4 is similar).
    var nominalSurfaceSize: (width: Int, height: Int) {
        (Int(surfaceWidth), Int(surfaceHeight))
    }

    // MARK: - GameController-framework feed
    //
    // macOS 14+ started surfacing DualSense / DualShock 4 touchpad
    // coordinates through the GameController framework's physical input
    // profile (as `GCDualSenseGamepad.touchpadPrimary / .touchpadSecondary`
    // direction pads). On those systems the helper subprocess returns
    // empty data because gamecontrollerd has the device open and the
    // touchpad bytes never reach our IOHIDManager.
    //
    // This entry point lets `GameControllerService` push the touchpad
    // values it reads from the profile straight into the same finger /
    // region pipeline the helper writes to. Coordinates are in the same
    // normalized -1...1 space the direction pads use; we remap into the
    // device-native (0..1920, 0..1080) box used for region matching and
    // calibration.
    func ingestGameControllerTouchpad(
        f0Active: Bool, f0NormalizedX: Float, f0NormalizedY: Float,
        f1Active: Bool, f1NormalizedX: Float, f1NormalizedY: Float
    ) {
        // GCDualSenseGamepad reports the touchpad as a direction pad:
        //   xAxis ∈ [-1, 1] with +1 at the RIGHT edge,
        //   yAxis ∈ [-1, 1] with +1 at the TOP.
        // The helper's coordinate convention has Y=0 at the TOP, so we
        // flip Y before mapping into native pixels.
        func nativeX(_ n: Float) -> Int {
            let clamped = max(-1, min(1, n))
            return Int((clamped + 1) / 2 * surfaceWidth)
        }
        func nativeY(_ n: Float) -> Int {
            let clamped = max(-1, min(1, n))
            return Int((1 - (clamped + 1) / 2) * surfaceHeight)
        }
        let f0X = nativeX(f0NormalizedX)
        let f0Y = nativeY(f0NormalizedY)
        let f1X = nativeX(f1NormalizedX)
        let f1Y = nativeY(f1NormalizedY)

        lock.lock()
        defer { lock.unlock() }

        // Use synthetic contact IDs so applyFinger's "same finger" delta
        // accumulation works the same way it does for helper-sourced
        // data. Bumping the ID on every lift-and-replace prevents huge
        // delta spikes on re-touch.
        if f0Active {
            let existingID = lastF0Pos?.id ?? 0
            applyFinger(active: true, id: existingID, x: f0X, y: f0Y,
                        last: &lastF0Pos, delta: &finger0Delta)
        } else {
            applyFinger(active: false, id: 0, x: 0, y: 0,
                        last: &lastF0Pos, delta: &finger0Delta)
        }
        if f1Active {
            let existingID = lastF1Pos?.id ?? 1
            applyFinger(active: true, id: existingID, x: f1X, y: f1Y,
                        last: &lastF1Pos, delta: &finger1Delta)
        } else {
            applyFinger(active: false, id: 0, x: 0, y: 0,
                        last: &lastF1Pos, delta: &finger1Delta)
        }
        updateCurrentPositions(f0Active: f0Active, f0X: f0X, f0Y: f0Y,
                               f1Active: f1Active, f1X: f1X, f1Y: f1Y)
    }

    // MARK: - Calibration

    func currentCalibration() -> TouchpadCalibration {
        lock.lock(); defer { lock.unlock() }
        return calibration
    }

    /// Persist a new calibration. Pass `.uncalibrated` to reset to defaults.
    /// Writes to BOTH `UserDefaults` and a JSON file in Application Support
    /// so that even if one storage layer hiccups (UserDefaults sync timing,
    /// container migration), the other will recover the value on next launch.
    func saveCalibration(_ new: TouchpadCalibration) {
        var stamped = new
        // Don't stamp the uncalibrated sentinel - that's a reset, not a save.
        if !(new.minX == TouchpadCalibration.uncalibrated.minX
             && new.maxX == TouchpadCalibration.uncalibrated.maxX
             && new.minY == TouchpadCalibration.uncalibrated.minY
             && new.maxY == TouchpadCalibration.uncalibrated.maxY) {
            stamped.savedAt = Date()
        }
        lock.lock()
        calibration = stamped
        lock.unlock()
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        UserDefaults.standard.set(data, forKey: Self.calibrationKey)
        try? data.write(to: Self.calibrationFileURL, options: .atomic)
        #if DEBUG
        print("[TouchpadService] saved calibration: X \(stamped.minX)-\(stamped.maxX) Y \(stamped.minY)-\(stamped.maxY) at \(String(describing: stamped.savedAt)) → \(Self.calibrationFileURL.path)")
        #endif
    }

    /// A calibration is usable only when both axes have a positive span. A
    /// persisted inverted or degenerate range (maxX <= minX, from a corrupt
    /// file or a half-finished sweep) would otherwise collapse the divisor and
    /// make the axis wildly oversensitive.
    private static func isValidCalibration(_ c: TouchpadCalibration) -> Bool {
        return c.maxX > c.minX && c.maxY > c.minY
    }

    private func loadCalibration() {
        // Prefer the on-disk file (more reliable across container migrations),
        // fall back to UserDefaults for older installs.
        if let data = try? Data(contentsOf: Self.calibrationFileURL),
           let decoded = try? JSONDecoder().decode(TouchpadCalibration.self, from: data),
           Self.isValidCalibration(decoded) {
            calibration = decoded
            #if DEBUG
            print("[TouchpadService] loaded calibration from file: X \(decoded.minX)-\(decoded.maxX) Y \(decoded.minY)-\(decoded.maxY)")
            #endif
            return
        }
        if let data = UserDefaults.standard.data(forKey: Self.calibrationKey),
           let decoded = try? JSONDecoder().decode(TouchpadCalibration.self, from: data),
           Self.isValidCalibration(decoded) {
            calibration = decoded
            // Promote to the file store so future reads use the canonical path.
            try? data.write(to: Self.calibrationFileURL, options: .atomic)
            #if DEBUG
            print("[TouchpadService] loaded calibration from UserDefaults: X \(decoded.minX)-\(decoded.maxX) Y \(decoded.minY)-\(decoded.maxY)")
            #endif
        }
    }

    // MARK: - Active device (UI-only state)

    /// The device the calibration sheet was last operating on. Persisted
    /// so the picker re-opens to the same selection.
    func currentActiveDevice() -> TouchpadDevice {
        let raw = UserDefaults.standard.string(forKey: Self.activeDeviceKey) ?? ""
        return TouchpadDevice(rawValue: raw) ?? .dualSense
    }

    /// Remember the user's device pick for the next time the sheet opens.
    func setActiveDevice(_ device: TouchpadDevice) {
        UserDefaults.standard.set(device.rawValue, forKey: Self.activeDeviceKey)
    }

    // MARK: - Quick Zero

    /// Re-zero the per-finger motion baseline at the current finger position:
    /// the next delta is measured from here, so a relative touchpad-as-pointer
    /// preset continues smoothly without a jump when the user re-centers.
    ///
    /// NOTE: this intentionally does NOT shift region matching. Regions are
    /// matched against the absolute, normalized touchpad position (see
    /// recomputePressedRegions), so offsetting coordinates by a quick-zero
    /// origin would misalign every saved region. The origin is recorded only
    /// for diagnostics (quickZeroInfo); it is deliberately not applied to live
    /// coordinates. Returns true if a finger was actually in contact (so the UI
    /// can show a "needs finger on touchpad" hint when it wasn't).
    @discardableResult
    func quickZero() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = currentF0 ?? currentF1 else { return false }
        quickZeroOriginX = p.x
        quickZeroOriginY = p.y
        quickZeroAt = Date()
        // Clear accumulated deltas so an immediate read-after-zero returns
        // 0 instead of the motion that built up before the user pressed it.
        finger0Delta = FingerDelta()
        finger1Delta = FingerDelta()
        lastF0Pos = nil
        lastF1Pos = nil
        return true
    }

    /// Reset Quick Zero so coordinates are read raw again.
    func clearQuickZero() {
        lock.lock(); defer { lock.unlock() }
        quickZeroOriginX = 0
        quickZeroOriginY = 0
        quickZeroAt = nil
    }

    /// Snapshot of the current Quick Zero offset (relative to raw helper
    /// coordinates) and when it was set. `at == nil` means no zero is
    /// active.
    func quickZeroInfo() -> (x: Int, y: Int, at: Date?) {
        lock.lock(); defer { lock.unlock() }
        return (quickZeroOriginX, quickZeroOriginY, quickZeroAt)
    }

    /// On-disk calibration location. Lives in the same Application Support
    /// directory as presets so it's covered by the Export Backup feature.
    private static let calibrationFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("touchpadCalibration.json")
    }()

    // MARK: - Regions

    /// Snapshot of the current region list. UI iterates over this.
    func allRegions() -> [TouchpadRegion] {
        lock.lock(); defer { lock.unlock() }
        return regions
    }

    /// Look up a region by ID. Returns nil if it's been deleted.
    func region(with id: UUID) -> TouchpadRegion? {
        lock.lock(); defer { lock.unlock() }
        return regions.first(where: { $0.id == id })
    }

    /// Pressed set with expired tap-latches dropped at read time. A fast tap
    /// that lands between poll frames stays visible for its latch window, but
    /// once the latch elapses no future finger event would prune it, so we
    /// check expiry here. Held fingers keep refreshing their expiry via the
    /// continuous ingest path, so they are never dropped early. Call locked.
    private func livePressedRegionsLocked() -> Set<UUID> {
        let now = ProcessInfo.processInfo.systemUptime
        return pressedRegions.filter { (regionPressExpiry[$0] ?? .infinity) > now }
    }

    /// True when any finger is currently inside the region.
    func isRegionPressed(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pressedRegions.contains(id) else { return false }
        return (regionPressExpiry[id] ?? .infinity) > ProcessInfo.processInfo.systemUptime
    }

    /// Combined regions + pressed-set snapshot under a single lock
    /// acquisition. Cheaper than calling allRegions() + isRegionPressed()
    /// per region (which would take 1 + N locks). Used by view-side
    /// polling that needs both pieces of state per frame.
    func snapshotRegions() -> (regions: [TouchpadRegion], pressed: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        return (regions, livePressedRegionsLocked())
    }

    // MARK: - Gesture detection

    /// True for exactly one read after a two-finger tap is detected
    /// (both fingers touched and lifted within ~250ms with very little
    /// motion). The engine's 120 Hz poll consumes the flag via
    /// `consumeGesture(_:)`. View-side observers should use
    /// `peekGesture(_:)` so they don't steal the engine's wake-up.
    private var pendingGesture: TouchpadGestureKind?
    /// Time the current two-finger gesture window started, or nil when
    /// fewer than two fingers are down. Monotonic CACurrentMediaTime
    /// seconds so it doesn't pay Date allocation on every HID report.
    private var twoFingerStartedAt: CFTimeInterval?
    /// Accumulated motion magnitude (in native units) during the window.
    /// We cancel the tap if either finger moved more than `tapMotionLimit`.
    private var twoFingerMotionMagnitude: Double = 0
    private let tapMaxDuration: CFTimeInterval = 0.30
    private let tapMotionLimit: Double = 180    // native px (DualSense 1920x1080)

    /// Returns true for ~80 ms after a gesture fires, then false.
    /// The engine's poll loop sees this as a press-then-release edge
    /// (true on the first read after the gesture detector flagged it,
    /// false on the subsequent reads), which is what every other
    /// binding type expects. The previous "return true exactly once"
    /// version never produced the falling edge so outputs bound to
    /// a gesture only fired a press, never the release - any output
    /// that depends on release (key-up, mouse-button-up, MIDI
    /// note-off) was left stuck.
    func consumeGesture(_ kind: TouchpadGestureKind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingGesture == kind else { return false }
        let now = CACurrentMediaTime()
        if gestureFiredAt == nil {
            gestureFiredAt = now
            return true
        }
        // Hold the active flag for the hold window so the engine
        // polls see one or two more "true" reads before flipping to
        // false on its own re-read. After the window we clear and
        // start producing false again.
        if now - (gestureFiredAt ?? 0) < gestureHoldWindow {
            return true
        }
        pendingGesture = nil
        gestureFiredAt = nil
        return false
    }
    private var gestureFiredAt: CFTimeInterval?
    private let gestureHoldWindow: CFTimeInterval = 0.08

    /// Read-only check that doesn't clear the flag. Useful for
    /// view-side indicators.
    func peekGesture(_ kind: TouchpadGestureKind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingGesture == kind
    }

    /// Run the gesture state machine against the latest finger state.
    /// Called from `updateCurrentPositions` so it sees the same data
    /// the region matcher uses.
    fileprivate func updateGestureDetector(
        f0Active: Bool, f0DX: Float, f0DY: Float,
        f1Active: Bool, f1DX: Float, f1DY: Float
    ) {
        let nowMono = CACurrentMediaTime()
        let bothDown = f0Active && f1Active
        if bothDown {
            if twoFingerStartedAt == nil {
                twoFingerStartedAt = nowMono
                twoFingerMotionMagnitude = 0
            } else {
                // Accumulate per-frame motion on both fingers.
                let dm = Double(abs(f0DX) + abs(f0DY) + abs(f1DX) + abs(f1DY))
                twoFingerMotionMagnitude += dm
            }
        } else if let started = twoFingerStartedAt {
            // Both-down window ended. Decide tap vs ignore.
            let elapsed = nowMono - started
            if elapsed <= tapMaxDuration
                && twoFingerMotionMagnitude <= tapMotionLimit
                && !f0Active && !f1Active {
                pendingGesture = .twoFingerTap
            }
            twoFingerStartedAt = nil
            twoFingerMotionMagnitude = 0
        }
    }

    /// Replace the region list and persist. UI calls this after add / edit /
    /// delete operations.
    func saveRegions(_ newRegions: [TouchpadRegion]) {
        lock.lock()
        regions = newRegions
        // Drop pressed-state entries for regions that no longer exist.
        pressedRegions = pressedRegions.filter { id in newRegions.contains(where: { $0.id == id }) }
        lock.unlock()
        if let data = try? JSONEncoder().encode(newRegions) {
            UserDefaults.standard.set(data, forKey: Self.regionsKey)
        }
    }

    private func loadRegions() {
        if let data = UserDefaults.standard.data(forKey: Self.regionsKey),
           let decoded = try? JSONDecoder().decode([TouchpadRegion].self, from: data) {
            regions = decoded
        }
    }

    /// Minimum time a region stays "pressed" after a finger touches it. A
    /// light tap can land and lift between two engine poll frames; without
    /// the latch the press was overwritten before the poll loop ever saw it,
    /// so quick regional taps silently did nothing.
    private let regionPressLatch: TimeInterval = 0.04
    private var regionPressExpiry: [UUID: TimeInterval] = [:]

    /// Recompute which regions are currently pressed based on the latest
    /// finger positions. Called from `updateCurrentPositions`.
    private func recomputePressedRegions(f0Active: Bool, f0X: Int, f0Y: Int,
                                         f1Active: Bool, f1X: Int, f1Y: Int) {
        guard !regions.isEmpty else {
            pressedRegions.removeAll()
            regionPressExpiry.removeAll()
            return
        }
        var pressed = Set<UUID>()
        let w = Double(surfaceWidth), h = Double(surfaceHeight)
        let now = ProcessInfo.processInfo.systemUptime
        for region in regions {
            if f0Active && region.contains(normalizedX: Double(f0X) / w, y: Double(f0Y) / h) {
                pressed.insert(region.id)
                regionPressExpiry[region.id] = now + regionPressLatch
            } else if f1Active && region.contains(normalizedX: Double(f1X) / w, y: Double(f1Y) / h) {
                pressed.insert(region.id)
                regionPressExpiry[region.id] = now + regionPressLatch
            }
        }
        // Keep recently tapped regions pressed until their latch expires so
        // every tap stays observable for at least one poll frame, then prune
        // expired entries so the dictionary cannot grow.
        for (id, expiry) in regionPressExpiry where expiry > now {
            pressed.insert(id)
        }
        regionPressExpiry = regionPressExpiry.filter { $0.value > now }
        pressedRegions = pressed
    }

    // MARK: - Stdout parsing

    private var stdoutBuffer = Data()

    private func consumeStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                handleLine(line)
            }
        }
        // Guard against a malformed helper flooding a newline-less stream: cap
        // the unparsed buffer so it can't grow without bound.
        if stdoutBuffer.count > 65_536 {
            stdoutBuffer.removeAll(keepingCapacity: false)
        }
    }

    /// Format: "T <seq> <btn> <f0Active> <f0Id> <f0X> <f0Y> <f1Active> <f1Id> <f1X> <f1Y> <kind>"
    /// Also:   "B <buttons1> <buttons2> <kind>" - the raw DualSense button
    /// bytes, emitted by the helper only when either byte changes. The older
    /// two-field form is accepted for compatibility with an already-running
    /// helper during an app upgrade.
    private func handleLine(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        // Surface non-T messages from the helper so we can see startup
        // handshakes ("R ready"), device-attach events ("A dualsense"),
        // and errors. T lines are the input stream and would flood the
        // log if we printed them, so they're filtered out. B lines fire
        // once per press/release edge, so logging them doubles as the
        // press diagnostic for the Edge extras.
        if parts.first != "T" {
            NSLog("[TouchpadHelper STDOUT] %@", line)
        }
        if parts.first == "B", parts.count >= 2 {
            let b1: UInt8
            let b2: UInt8
            if parts.count >= 3, let parsedB1 = UInt8(parts[1]), let parsedB2 = UInt8(parts[2]) {
                b1 = parsedB1
                b2 = parsedB2
            } else if let parsedB2 = UInt8(parts[1]) {
                b1 = 0
                b2 = parsedB2
            } else {
                return
            }
            DualSenseSupplementService.shared.ingestHelperButtons2(b2, buttons1: b1)
            return
        }
        guard parts.first == "T", parts.count >= 11,
              let f0Active = UInt8(parts[3]),
              let f0Id = UInt8(parts[4]),
              let f0X = Int(parts[5]),
              let f0Y = Int(parts[6]),
              let f1Active = UInt8(parts[7]),
              let f1Id = UInt8(parts[8]),
              let f1X = Int(parts[9]),
              let f1Y = Int(parts[10]) else { return }

        lock.lock()
        defer { lock.unlock() }

        applyFinger(active: f0Active != 0, id: f0Id, x: f0X, y: f0Y,
                    last: &lastF0Pos, delta: &finger0Delta)
        applyFinger(active: f1Active != 0, id: f1Id, x: f1X, y: f1Y,
                    last: &lastF1Pos, delta: &finger1Delta)
        updateCurrentPositions(f0Active: f0Active != 0, f0X: f0X, f0Y: f0Y,
                               f1Active: f1Active != 0, f1X: f1X, f1Y: f1Y)
    }

    private func applyFinger(active: Bool, id: UInt8, x: Int, y: Int,
                             last: inout (id: UInt8, x: Int, y: Int)?,
                             delta: inout FingerDelta) {
        delta.active = active
        if !active {
            last = nil
            return
        }
        // Same finger as before? Accumulate delta. Otherwise reset baseline
        // so a finger-lift-and-replace doesn't produce a jump.
        if let prev = last, prev.id == id {
            delta.dx += Float(x - prev.x)
            delta.dy += Float(y - prev.y)
        }
        last = (id, x, y)
    }

    /// Write the latest absolute positions to the public `currentF0`/`currentF1`
    /// slots so the calibration view can read them in real time.
    private func updateCurrentPositions(f0Active: Bool, f0X: Int, f0Y: Int,
                                        f1Active: Bool, f1X: Int, f1Y: Int) {
        // Compute per-update deltas vs the previous positions so the
        // gesture detector can see how much each finger moved during
        // this sample. Only the absolute values matter (magnitude), so
        // sign is dropped before the accumulator sums them in
        // updateGestureDetector.
        let f0PrevX = currentF0?.x ?? f0X
        let f0PrevY = currentF0?.y ?? f0Y
        let f1PrevX = currentF1?.x ?? f1X
        let f1PrevY = currentF1?.y ?? f1Y

        currentF0 = f0Active ? (f0X, f0Y) : nil
        currentF1 = f1Active ? (f1X, f1Y) : nil
        recomputePressedRegions(f0Active: f0Active, f0X: f0X, f0Y: f0Y,
                                f1Active: f1Active, f1X: f1X, f1Y: f1Y)

        let f0dx = f0Active ? Float(f0X - f0PrevX) : 0
        let f0dy = f0Active ? Float(f0Y - f0PrevY) : 0
        let f1dx = f1Active ? Float(f1X - f1PrevX) : 0
        let f1dy = f1Active ? Float(f1Y - f1PrevY) : 0
        updateGestureDetector(f0Active: f0Active, f0DX: f0dx, f0DY: f0dy,
                              f1Active: f1Active, f1DX: f1dx, f1DY: f1dy)
    }

    // MARK: - Helper discovery

    private func helperPath() -> URL? {
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("TouchpadHelper"),
           FileManager.default.isExecutableFile(atPath: bundlePath.path) {
            return bundlePath
        }
        if let resourcePath = Bundle.main.url(forResource: "TouchpadHelper", withExtension: nil) {
            return resourcePath
        }
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TouchpadHelper/TouchpadHelper")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }
        return nil
    }
}
