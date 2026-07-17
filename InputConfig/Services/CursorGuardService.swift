import Foundation
import AppKit
import CoreGraphics
import Combine

/// Gaming-oriented cursor utilities. Optional, all-off by default so
/// the app's normal "I move my mouse, the OS moves it" behaviour is
/// preserved. Each feature toggles independently:
///
///   - **Edge confine**: keeps the cursor at least `edgeBufferPx`
///     pixels away from any screen edge by warping it back inward.
///     Useful for FPS / 3D camera games that read mouse delta but the
///     cursor still hits the edge of the screen and stops moving.
///
///   - **Auto-recenter**: every `recenterIntervalMs` the cursor is
///     teleported back to the screen centre (or a user-defined
///     anchor). Mirrors what tools like X-Mouse Button Control offer
///     on Windows. Together with edge-confine, lets the user play any
///     game that needs unbounded mouselook on a captive cursor.
///
///   - **Hide while engine running**: hides the system cursor while
///     the MappingEngine is active (since the controller is driving
///     input anyway, a floating cursor is just visual noise). Restores
///     it on stop.
///
///   - **Sensitivity multiplier**: scales OS cursor movement by a
///     constant factor by tracking deltas and re-warping. Independent
///     of macOS's own tracking-speed slider.
///
///   - **Sticky-to-anchor**: while the configured modifier key is
///     held, every mouse delta is suppressed and the cursor stays at
///     the anchor. Lets the user define a "hold to lock cursor" hotkey
///     for top-down games where the cursor should park dead centre.
///
/// All warping uses `CGWarpMouseCursorPosition`, which is a public API
/// and works without accessibility permissions because we're moving
/// the cursor, not synthesising clicks. The class lives on the main
/// actor since CG calls expect it.
@MainActor
final class CursorGuardService: ObservableObject {

    static let shared = CursorGuardService()

    // MARK: - User-tunable settings (persisted via @AppStorage in the UI)

    @Published var edgeConfineEnabled: Bool = UserDefaults.standard.bool(forKey: "CursorGuard.edgeConfine") {
        didSet { UserDefaults.standard.set(edgeConfineEnabled, forKey: "CursorGuard.edgeConfine"); restartLoop() }
    }
    @Published var edgeBufferPx: Double = max(1, UserDefaults.standard.double(forKey: "CursorGuard.edgeBufferPx").nonZeroOrDefault(24)) {
        didSet { UserDefaults.standard.set(edgeBufferPx, forKey: "CursorGuard.edgeBufferPx") }
    }
    @Published var autoRecenterEnabled: Bool = UserDefaults.standard.bool(forKey: "CursorGuard.autoRecenter") {
        didSet { UserDefaults.standard.set(autoRecenterEnabled, forKey: "CursorGuard.autoRecenter"); restartLoop() }
    }
    @Published var recenterIntervalMs: Double = max(50, UserDefaults.standard.double(forKey: "CursorGuard.recenterIntervalMs").nonZeroOrDefault(500)) {
        didSet { UserDefaults.standard.set(recenterIntervalMs, forKey: "CursorGuard.recenterIntervalMs"); restartLoop() }
    }
    @Published var hideCursorWhileEngineRunning: Bool = UserDefaults.standard.bool(forKey: "CursorGuard.hideWhileRunning") {
        didSet { UserDefaults.standard.set(hideCursorWhileEngineRunning, forKey: "CursorGuard.hideWhileRunning"); applyHideState() }
    }
    /// User-tunable sensitivity multiplier applied to cursor utilities.
    /// Clamped on both ends: floor of 0.1 prevents a near-zero value
    /// from disabling cursor movement entirely (looks like a bug), and
    /// the new ceiling of 5.0 stops a saved value from a previous
    /// build's wider range producing a cursor that overshoots a
    /// thousand pixels per frame.
    @Published var sensitivityMultiplier: Double = min(5.0, max(0.1, UserDefaults.standard.double(forKey: "CursorGuard.sensitivity").nonZeroOrDefault(1.0))) {
        didSet {
            // Clamp on every write so the live slider can't escape the
            // safe range either - the persisted value follows the
            // clamped one rather than the raw input.
            let clamped = min(5.0, max(0.1, sensitivityMultiplier))
            if clamped != sensitivityMultiplier {
                sensitivityMultiplier = clamped
                return // didSet re-fires once with the clamped value
            }
            UserDefaults.standard.set(sensitivityMultiplier, forKey: "CursorGuard.sensitivity")
        }
    }

    /// True only while the engine is actively running. Set externally
    /// by MappingEngine.start/stop hooks. Drives `hideCursorWhileEngineRunning`.
    @Published private(set) var engineActive: Bool = false {
        didSet { applyHideState() }
    }

    /// Per-preset overrides applied on top of the global toggles when
    /// the engine is running. nil = no override (use the user's
    /// global Settings → Gaming Utilities choices). Non-nil = the
    /// preset's PresetAutomation values temporarily replace the
    /// effective values while the engine is active.
    private var presetOverride: PresetAutomation?

    private init() {
        // Restart in case any persisted flag was already on.
        restartLoop()
    }

    /// Adopt the given preset's automation as the active override.
    /// Called by MappingEngine.start. While set, the service's
    /// effective behaviour is driven entirely by these values rather
    /// than the global @Published toggles. Persisted user settings
    /// are untouched.
    func applyPresetOverride(_ automation: PresetAutomation) {
        presetOverride = automation
        restartLoop()
        applyHideState()
    }

    /// Drop the preset override and fall back to global toggles.
    /// Called by MappingEngine.stop.
    func clearPresetOverride() {
        presetOverride = nil
        restartLoop()
        applyHideState()
    }

    // Effective values: preset override > global toggle.
    private var effectiveConfineEnabled: Bool {
        presetOverride?.confineCursor ?? edgeConfineEnabled
    }
    private var effectiveBufferPx: Double {
        presetOverride?.confineBufferPx ?? edgeBufferPx
    }
    private var effectiveRecenterEnabled: Bool {
        presetOverride?.autoRecenterCursor ?? autoRecenterEnabled
    }
    private var effectiveRecenterIntervalMs: Double {
        presetOverride?.autoRecenterIntervalMs ?? recenterIntervalMs
    }
    private var effectiveHideCursor: Bool {
        presetOverride?.hideCursorWhileActive ?? hideCursorWhileEngineRunning
    }

    // MARK: - Engine integration

    /// Called from MappingEngine.start/stop so the cursor guard can
    /// react to the engine going active or idle (hide cursor / unhide,
    /// kick the recenter timer awake, etc.).
    func engineDidChangeState(running: Bool) {
        engineActive = running
        restartLoop()
    }

    // MARK: - Recenter loop

    private var loopTimer: Timer?
    private var cursorHidden = false

    /// Tear down and rebuild the periodic guard loop with current
    /// settings. Called any time a relevant toggle / interval changes.
    /// Per the user's request, cursor utilities only run WHILE a
    /// preset is active - so the loop is a no-op when `engineActive`
    /// is false even if the toggles are on. This avoids the cursor
    /// jumping around while the user is editing a preset.
    private func restartLoop() {
        loopTimer?.invalidate()
        loopTimer = nil
        guard engineActive else { return }
        guard effectiveConfineEnabled || effectiveRecenterEnabled else { return }
        // Use the shorter of the two intervals so edge-confine is
        // reactive; auto-recenter fires only when its own counter
        // expires.
        let intervalSec = max(0.02, effectiveRecenterIntervalMs / 1000.0)
        let confineTickHz: Double = effectiveConfineEnabled ? 60.0 : 1.0 / intervalSec
        let tickInterval = min(intervalSec, 1.0 / confineTickHz)
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            // Main-thread timer, so run inline instead of a per-tick Task
            // (allocation + hop up to 60x/second while confine is active).
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        loopTimer = t
        recenterAccumulator = 0
    }

    private var recenterAccumulator: TimeInterval = 0
    private var lastTickAt: TimeInterval = 0

    private func tick() {
        let now = Date().timeIntervalSince1970
        let dt = lastTickAt == 0 ? 0 : (now - lastTickAt)
        lastTickAt = now

        if effectiveConfineEnabled {
            applyEdgeConfine()
        }
        if effectiveRecenterEnabled {
            recenterAccumulator += dt
            if recenterAccumulator * 1000.0 >= effectiveRecenterIntervalMs {
                recenterAccumulator = 0
                warpToAnchor()
            }
        }
    }

    // MARK: - Geometry helpers

    /// Frame of the screen containing the current cursor position, or
    /// the main screen as a fallback. Note: NSScreen frames are in
    /// AppKit's bottom-up coords; CGWarpMouseCursorPosition expects
    /// top-down. We convert between the two.
    private func screenForCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        return NSScreen.main
    }

    /// Cursor position in top-left-origin global coords (the system
    /// "Quartz" space).
    /// The primary (zero-origin) screen defines the global coordinate space.
    /// The Quartz top-left flip must reference ITS height, not NSScreen.main
    /// (the focused screen), or on a multi-display setup the cursor warps to
    /// the wrong Y.
    private var primaryScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
    }

    private func cursorPositionTopLeft() -> CGPoint? {
        guard let screen = primaryScreen else { return nil }
        let mouse = NSEvent.mouseLocation
        let flippedY = screen.frame.height - mouse.y
        return CGPoint(x: mouse.x, y: flippedY)
    }

    /// Top-left-origin global rect of the given NSScreen.
    private func screenRectTopLeft(_ screen: NSScreen) -> CGRect {
        guard let main = primaryScreen else { return screen.frame }
        let f = screen.frame
        let flippedY = main.frame.height - (f.origin.y + f.height)
        return CGRect(x: f.origin.x, y: flippedY, width: f.width, height: f.height)
    }

    // MARK: - Behaviours

    /// If the cursor is within `edgeBufferPx` of any edge of its
    /// current screen, warp it back inside the buffer. The user still
    /// sees a smooth motion because we don't fight every frame - the
    /// 60 Hz tick is enough that a fast swipe to the edge clamps but
    /// slow movement is unaffected.
    private func applyEdgeConfine() {
        guard let screen = screenForCursor(),
              let pos = cursorPositionTopLeft() else { return }
        let frame = screenRectTopLeft(screen)
        let buf = CGFloat(effectiveBufferPx)
        var nx = pos.x, ny = pos.y, changed = false
        if nx < frame.minX + buf { nx = frame.minX + buf; changed = true }
        if nx > frame.maxX - buf { nx = frame.maxX - buf; changed = true }
        if ny < frame.minY + buf { ny = frame.minY + buf; changed = true }
        if ny > frame.maxY - buf { ny = frame.maxY - buf; changed = true }
        if changed {
            CGWarpMouseCursorPosition(CGPoint(x: nx, y: ny))
        }
    }

    /// Teleport the cursor back to the centre of the screen it's on.
    /// Future work: per-screen / per-app anchor points.
    func warpToAnchor() {
        guard let screen = screenForCursor() else { return }
        let frame = screenRectTopLeft(screen)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        CGWarpMouseCursorPosition(centre)
    }

    /// CG cursor hide/show toggle, matched to the engine-running state.
    private func applyHideState() {
        let shouldHide = engineActive && effectiveHideCursor
        if shouldHide, !cursorHidden {
            CGDisplayHideCursor(CGMainDisplayID())
            cursorHidden = true
        } else if !shouldHide, cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
    }

    /// Force the cursor visible regardless of our local hide-state
    /// tracker. Called from emergency-stop paths so an app exit while
    /// the cursor was hidden doesn't leave the system without a
    /// visible cursor until the user logs out. CGDisplayShowCursor is
    /// reference-counted by macOS, so even if we lost track of our
    /// hide count, calling it a few times in a row is safe.
    func forceShowCursor() {
        // Pop the CG hide ref-count down a few times in case we drifted.
        // Each Hide takes a ref; Show drops one. After 3 attempts the
        // cursor is almost certainly visible whatever state we were in.
        for _ in 0..<3 {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        cursorHidden = false
    }
}

private extension Double {
    /// Treat 0 as "missing" since UserDefaults.double returns 0 when
    /// the key isn't set. Lets us thread a default through without
    /// reading object(forKey:) and force-casting.
    func nonZeroOrDefault(_ fallback: Double) -> Double {
        self == 0 ? fallback : self
    }
}
