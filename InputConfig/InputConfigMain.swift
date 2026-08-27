import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    let presetStore = PresetStore()
    let controllerService = GameControllerService()
    let eightBitDoDetector = EightBitDoDetector()
    lazy var mappingEngine = MappingEngine(controllerService: controllerService)
    let crashRecovery = CrashRecoveryService.shared
    let freezeWatchdog = FreezeWatchdogService.shared
    let externalInput = ExternalInputDeviceService.shared
    let accessibility = AccessibilityPermissionService.shared

    init() {
        // Registered (volatile) defaults, applied whenever a key is unset.
        // Polling defaults to the power-source auto-switch mode so a fresh
        // install already adapts its rate to AC vs battery; the engine reads
        // these keys directly, so registering here (not just in @AppStorage)
        // is what makes "auto" the real default before Settings is ever opened.
        // NOTE: deliberately NOT registering pollHzOnAC/pollHzOnBattery/pollHz.
        // MappingEngine falls back to the user's chosen pollHz when the
        // per-source keys are unset; registering 120 here made that fallback
        // dead and silently downgraded existing users who had picked a
        // higher rate before this update.
        UserDefaults.standard.register(defaults: [
            "InputConfig.autoPollHzByPower": true,
            "InputConfig.showDockIcon": true,
        ])
        // The app is designed dark-first; in light mode the frosted-glass
        // surfaces wash out to near-white. Force the dark appearance app-wide
        // (windows, sheets, menus, popovers) regardless of the system setting.
        // Go through NSApplication.shared, never the NSApp global. NSApp is an
        // implicitly unwrapped NSApplication! that stays nil until the shared
        // instance exists, and on macOS 14 this initializer runs while SwiftUI
        // builds the scene graph straight from main, before that happens - so
        // touching NSApp here trapped at launch for every Sonoma user.
        // NSApplication.shared is non-optional and creates the instance.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        // Boot the freeze watchdog before any heavy work runs - this is the
        // earliest place the main actor is alive, so we get the most
        // accurate "main thread responsiveness" baseline.
        _ = freezeWatchdog
        // Boot the external HID enumeration too, so keyboards / mice are
        // already detected by the time the user opens Settings → Devices
        // or the binding editor's external-source picker.
        _ = externalInput
        // Boot the Accessibility-permission watcher so its trust state is
        // known at launch and refreshes when we return to the foreground.
        _ = accessibility
        // Register the global "toggle most recent preset" hotkey if the user
        // turned it on in Settings, so it works app-wide from launch.
        if UserDefaults.standard.bool(forKey: GlobalHotKeyService.enabledDefaultsKey) {
            GlobalHotKeyService.shared.enable()
        }
        // If the previous session ended abnormally and the user hasn't
        // opted out of session restore, re-activate whichever preset
        // was active at the time of the crash. Deferred to the next
        // run-loop tick so PresetStore has finished its disk load.
        DispatchQueue.main.async { [presetStore, crashRecovery, mappingEngine] in
            guard let id = crashRecovery.consumeRestoreTarget() else { return }
            if let preset = presetStore.presets.first(where: { $0.id == id }) {
                presetStore.activatePreset(preset)
                // Restore must also START the engine, not just mark the preset
                // active in the UI; otherwise the user's only input device
                // silently does nothing after a crash-recovery restore.
                mappingEngine.start(with: preset)
            }
        }

        // Graceful shutdown. When the user quits, NSApplication posts
        // willTerminate one main-runloop tick before exit; observing it
        // here gives us a deterministic window to release controller
        // state, stop the engine (which flushes pressed keys / mouse
        // buttons via releaseAll), close light-bar helpers, and persist
        // any pending stats. Without this, the process exits with
        // synthesized inputs still "down" in the OS event tap, so a
        // turbo'd or held key carries past the app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.gracefulShutdown()
        }
    }

    /// Show or hide the app's Dock icon (and, with it, the top menu bar and
    /// Cmd-Tab entry). Hiding it makes InputConfig a menu bar-only agent app.
    /// The caller guarantees at least one of {Dock icon, menu bar icon} stays
    /// visible so the app is always reachable.
    static func applyDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        // Re-activate on BOTH paths: switching to .accessory otherwise drops
        // the app behind whatever is next, which reads as the window
        // vanishing the moment the toggle is flipped. One runloop turn lets
        // the policy change land first.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Tear down outputs in priority order. Called on willTerminate.
    /// Each step is best-effort - a failure in one shouldn't block
    /// the others. Wraps in a fileprivate method so it's available
    /// from the observer closure above.
    fileprivate func gracefulShutdown() {
        // 0. Flush stats synchronously so the session's counters and time
        //    rollup are on disk before the process exits. The periodic flush
        //    writes asynchronously and may not complete at Cmd+Q.
        StatsService.shared.flushSynchronously()
        // 1. Stop the mapping engine. Releases held keys / mouse
        //    buttons / MIDI notes via the engine's stop() path.
        mappingEngine.stop()
        // 2. Deactivate the active preset record so a re-launch
        //    doesn't think a preset was already running.
        presetStore.deactivateAll()
        // 3. Belt-and-suspenders: drop everything the InputSimulator
        //    still considers pressed. Catches any synthesized keys
        //    the engine didn't track (e.g. macro mid-flight).
        InputSimulator.shared.releaseAll()
        // 4. Close the system-wide CGEventTap + IOHIDManager. Without
        //    this the mach port + runloop source linger past process
        //    exit, blocking a re-launch from grabbing a fresh tap
        //    until the kernel garbage-collects (can take 30+ seconds
        //    on a busy session).
        externalInput.teardownForTermination()
        // 5. Force the system cursor visible. If a preset had
        //    `hideCursorWhileActive` on and the user quit mid-session,
        //    we'd otherwise leave the cursor hidden until login - which
        //    looks indistinguishable from a frozen Mac.
        CursorGuardService.shared.forceShowCursor()
    }
}

/// The app's own controller artwork (the same glyph as the menu bar icon)
/// as a tintable inline icon. Drop-in replacement for the "gamecontroller"
/// SF Symbol so the custom artwork shows everywhere the app pictures a
/// controller. `height` approximates the point size of the symbol replaced.
struct ControllerGlyph: View {
    var height: CGFloat = 13

    var body: some View {
        Image("ControllerGlyph")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
    }
}

/// Icon-by-name renderer: game-controller SF Symbol names render the
/// custom ControllerGlyph artwork; every other name falls through to
/// Image(systemName:). `glyphHeight` sizes only the custom glyph - SF
/// Symbols keep sizing through .font at the call site as usual.
struct IconView: View {
    let name: String
    var glyphHeight: CGFloat = 13

    var body: some View {
        if name.hasPrefix("gamecontroller") {
            ControllerGlyph(height: glyphHeight)
        } else {
            Image(systemName: name)
        }
    }
}

/// Menu-safe controller icon. macOS menus (Menu / Picker `.menu`) ignore the
/// resize hint on a custom image and fall back to the asset's intrinsic size,
/// so a menu item must use a dedicated small-intrinsic asset rather than the
/// resizable `ControllerGlyph` (which would render at the full viewBox size).
/// The menu bar and every inline use keep the plain `ControllerGlyph` asset,
/// so the two never fight over one intrinsic size. Non-controller names fall
/// through to the SF Symbol.
struct MenuIcon: View {
    let name: String
    var body: some View {
        if name.hasPrefix("gamecontroller") {
            Image("ControllerGlyphMenu").renderingMode(.template)
        } else {
            Image(systemName: name)
        }
    }
}

/// Behind-window vibrancy that gives the app's windows the classic frosted,
/// translucent macOS look, and makes the host window non-opaque so the blur
/// reaches the desktop behind it. Reused by every window in the app so they
/// all share the same treatment.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// Optional solid tint laid over the vibrancy. The behind-window blur can
    /// read a touch too transparent on a busy desktop; a small tint (7% of the
    /// window background color) firms the surface up without going opaque.
    /// 0 = pure vibrancy (the default for sheets/secondary windows).
    var tintOpacity: Double = 0

    private static let tintViewID = NSUserInterfaceItemIdentifier("VEBTint")

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        if tintOpacity > 0 {
            let tint = NSView()
            tint.identifier = Self.tintViewID
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(tintOpacity).cgColor
            tint.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(tint)
            NSLayoutConstraint.activate([
                tint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                tint.topAnchor.constraint(equalTo: view.topAnchor),
                tint.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        // Once the view is in a window, drop the window's opacity so the
        // behind-window blur samples the desktop rather than a solid fill.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        // Re-resolve the tint against the current appearance so it tracks
        // light/dark switches (a stored CGColor would not).
        if tintOpacity > 0,
           let tint = nsView.subviews.first(where: { $0.identifier == Self.tintViewID }) {
            nsView.effectiveAppearance.performAsCurrentDrawingAppearance {
                tint.layer?.backgroundColor = NSColor.windowBackgroundColor
                    .withAlphaComponent(tintOpacity).cgColor
            }
        }
        // updateNSView runs after the view is mounted, so the window now
        // exists. makeNSView's early attempt saw a nil window, which is why
        // the translucency never took. Reassert it here.
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
    }
}

/// App-level accessibility preferences, settable in Settings > General >
/// Accessibility. These layer ON TOP of the system settings: the system's
/// Reduce Motion / Reduce Transparency are always honored, and these let the
/// user opt in per-app without changing their whole Mac.
enum AppA11y {
    static var reduceMotion: Bool {
        UserDefaults.standard.bool(forKey: "InputConfig.a11y.reduceMotion")
    }
    static var reduceTransparency: Bool {
        UserDefaults.standard.bool(forKey: "InputConfig.a11y.reduceTransparency")
    }

    /// Map the stored text-size step to a concrete Dynamic Type size.
    static func typeSize(forStep step: Int) -> DynamicTypeSize {
        switch step {
        case 1: return .xLarge
        case 2: return .xxxLarge
        case 3: return .accessibility1
        default: return .large
        }
    }
}

/// Applies the app-level accessibility preferences to a view tree: text
/// size, bold text, and the no-animation transaction gate. Environment
/// values (type size, legibility) flow into sheets and popovers on their
/// own; the transaction gate is re-applied inside glassBackground so
/// sheets get it too.
struct AccessibilityAdjustments: ViewModifier {
    @AppStorage("InputConfig.a11y.textSize") private var textSize = 0
    @AppStorage("InputConfig.a11y.boldText") private var boldText = false
    @AppStorage("InputConfig.a11y.reduceMotion") private var reduceMotionPref = false

    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(AppA11y.typeSize(forStep: textSize))
            .environment(\.legibilityWeight, boldText ? .bold : nil)
            .transaction { txn in
                if reduceMotionPref { txn.animation = nil }
            }
    }
}

/// The main window's behind-window backdrop, honoring Reduce Transparency:
/// frosted glass normally, a solid window background when the user asks.
private struct WindowBackdrop: ViewModifier {
    @AppStorage("InputConfig.a11y.reduceTransparency") private var reduceTransparency = false
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        } else {
            content.background(VisualEffectBackground(tintOpacity: 0.07).ignoresSafeArea())
        }
    }
}

/// Sheet backdrop half of the same rule.
private struct SheetBackdrop: ViewModifier {
    @AppStorage("InputConfig.a11y.reduceTransparency") private var reduceTransparency = false
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.presentationBackground { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
        } else {
            content.presentationBackground { VisualEffectBackground().ignoresSafeArea() }
        }
    }
}

extension View {
    /// App-level accessibility (text size, bold text, reduced motion).
    /// Apply once at each window root; sheets inherit the environment
    /// halves automatically.
    func appAccessibility() -> some View {
        modifier(AccessibilityAdjustments())
    }

    /// Presents this sheet over the same behind-window frosted glass as the
    /// main window, so every sheet shares one consistent translucency. Apply
    /// to the content inside a `.sheet { }` closure. Also carries the
    /// Reduce Motion gate so every sheet honors it without per-sheet wiring,
    /// and swaps to a solid backdrop under Reduce Transparency.
    func glassBackground() -> some View {
        modifier(SheetBackdrop())
            .reduceMotionFriendly()
            .appAccessibility()
    }

    /// Main-window backdrop honoring Reduce Transparency.
    func windowBackdrop() -> some View {
        modifier(WindowBackdrop())
    }

    /// System accessibility: when the user enables Reduce Motion, strip the
    /// animation out of every transaction that flows through this subtree, so
    /// state changes apply instantly instead of sliding/scaling/springing.
    /// Apply once at each root (window content, sheets, the menu bar popover).
    /// TimelineView-driven loops don't go through transactions and are gated
    /// individually at their call sites.
    func reduceMotionFriendly() -> some View {
        modifier(ReduceMotionGate())
    }
}

private struct ReduceMotionGate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { t in
            if reduceMotion { t.animation = nil }
        }
    }
}

// MARK: - Shared design language (see ~/Desktop/Apps/DesignSync)
//
// InputConfig converges on the same visual language as Aura and YapToText:
// real Liquid Glass cards, one spacing/radius scale, hierarchical SF Symbols,
// and colored icons that always carry a little transparency (never a flat
// solid block). Reference implementations were ported from YapToText's
// DesignSystem.swift rather than reinvented.

extension Color {
    /// The muted record/stop red shared with YapToText's menu bar (its
    /// `yapRecord`), so the Stop pill reads the same, not a harsh system red.
    static let icStop = Color(red: 0.80, green: 0.31, blue: 0.33)
}

/// One spacing scale for the whole app.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 10
    static let l: CGFloat = 14
}

/// One radius / padding scale. Replaces the old grab-bag of 3/4/5/6/7/8/10/12
/// literals scattered through the views.
enum Metrics {
    static let cardRadius: CGFloat = 18
    static let sectionRadius: CGFloat = 18
    /// Floating panels (the menu-bar popover) sit one notch tighter than cards.
    static let panelRadius: CGFloat = 14
    static let innerRadius: CGFloat = 10
    static let badgeRadius: CGFloat = 9
    static let cardPad: CGFloat = 14
    static let gap: CGFloat = 14
}

extension View {
    /// THE colored-icon treatment. A tinted SF Symbol is NEVER a flat 100%
    /// solid block of color: every colored icon carries a little transparency
    /// so it reads as a layered, glassy mark. Pairs with the global
    /// `.symbolRenderingMode(.hierarchical)`. Transparency only, never a
    /// gradient. Use in place of `.foregroundStyle(color)` on any colored icon.
    func iconTint(_ color: Color, opacity: Double = 0.85) -> some View {
        foregroundStyle(color.opacity(opacity))
    }

    /// The app's ONE glass surface treatment. Every glass surface in the app
    /// (cards, pills, CTAs, toasts, overlays) routes through this helper, so
    /// there is exactly one glass language and never a mixture.
    ///
    /// On macOS 26+ this is Apple's REAL Liquid Glass engine
    /// (`.glassEffect`), tinted and interactive as requested. On macOS 14-25
    /// (the App Store deployment floor) it falls back to a tinted material +
    /// hairline stroke with identical layout.
    ///
    /// Accessibility: when the user enables Reduce Transparency, every glass
    /// surface renders as an OPAQUE window-background fill instead (system
    /// materials partially self-adapt, but the tint washes and the macOS 26
    /// glass path are guaranteed here). When Increase Contrast is on, the
    /// hairline stroke doubles in weight and opacity.
    func liquidGlass<S: Shape>(in shape: S,
                               tint: Color? = nil,
                               interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    /// THE single flat inner-surface style: a quiet recess (NOT glass) for
    /// anything nested inside a glass card - icon badges, wells, tiles, rows.
    /// Glass-inside-glass double-frosts and reads darker; the card is the
    /// glass, everything nested is a recess so every box reads the same.
    func innerWell(radius: CGFloat = Metrics.innerRadius) -> some View {
        modifier(InnerWellModifier(radius: radius))
    }

    /// Shared hover affordance for custom `.plain` controls: a soft fill that
    /// fades in on hover, replacing the hand-rolled per-view hover backgrounds.
    func hoverFill(_ hovering: Bool, radius: CGFloat = Metrics.innerRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
    }
}

/// Environment-aware body for `liquidGlass(in:tint:interactive:)`.
/// Honors Reduce Transparency (opaque fill, no glass) and Increase
/// Contrast (heavier stroke) system accessibility settings.
private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var strokeOpacity: Double { contrast == .increased ? 0.5 : 0.12 }
    private var strokeWidth: CGFloat { contrast == .increased ? 1.0 : 0.5 }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(shape.fill((tint ?? Color.clear).opacity(0.25)))
                )
                .overlay(shape.stroke((tint ?? .primary).opacity(strokeOpacity),
                                      lineWidth: strokeWidth))
        } else if #available(macOS 26.0, *) {
            // Built in an inline closure so these imperative statements aren't
            // parsed as view content by the @ViewBuilder body (a bare var/if
            // here crashes swift-frontend in Release batch mode).
            let glass: Glass = {
                var g: Glass = .regular
                if let tint { g = g.tint(tint) }
                if interactive { g = g.interactive() }
                return g
            }()
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(
                    shape.fill(.thinMaterial)
                        // Tint wash so a tinted pill (Stop, hero CTA) keeps
                        // its color; untinted passes Color.clear -> no-op.
                        .overlay(shape.fill((tint ?? Color.clear).opacity(0.35)))
                )
                .overlay(shape.stroke((tint ?? .primary).opacity(strokeOpacity),
                                      lineWidth: strokeWidth))
        }
    }
}

/// Environment-aware body for `innerWell(radius:)`. Solid fills already
/// survive Reduce Transparency; Increase Contrast doubles the border.
private struct InnerWellModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.secondary.opacity(contrast == .increased ? 0.4 : 0.12),
                        lineWidth: contrast == .increased ? 1.0 : 0.5))
    }
}

extension View {

    /// The canonical scroll-edge treatment: fades content to transparent under
    /// the title band so it dissolves into the window vibrancy instead of
    /// colliding with the toolbar. Shared across Aura / InputConfig / YapToText
    /// with the tuned finals (height 76, mid-stop 0.35 @ 0.45). Apply once at
    /// the detail-pane level.
    func headerFade() -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.35), location: 0.45),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: 76)
                Rectangle().fill(.black)
            }
            .ignoresSafeArea()
        )
    }
}

/// A tinted SF Symbol on a glass squircle - translucent layered ink, never a
/// solid block of color. Ported from YapToText's IconBadge.
struct IconBadge: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 32
    /// True when `symbol` is the app's custom controller glyph rather than an
    /// SF Symbol, so the badge draws the artwork instead.
    var isGlyph: Bool = false

    var body: some View {
        Group {
            if isGlyph {
                ControllerGlyph(height: size * 0.5)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
            }
        }
        .iconTint(tint)
        .frame(width: size, height: size)
        .innerWell(radius: Metrics.badgeRadius)
        .accessibilityHidden(true)
    }
}

/// The workhorse container: a floating Liquid Glass card with a semibold
/// section-head title. Ported from YapToText's CardSection (using InputConfig's
/// availability-gated `liquidGlass` so it still builds on macOS 14).
struct CardSection<Content: View>: View {
    let title: String?
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.cardPad)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }
}

/// One flat button look across the app: a SOLID fill, no gradient or glass
/// sheen. Prominent = solid accent with white text; secondary = subtle neutral
/// fill. Ported from YapToText's SolidButton.
struct SolidButton: ButtonStyle {
    /// Three capsule sizes, one look: regular for sheet/hero rows, compact for
    /// dense utility rows, mini for the editor's per-binding micro buttons.
    enum Size { case regular, compact, mini }

    var tint: Color = .accentColor
    var prominent: Bool = true
    var size: Size = .regular
    @Environment(\.isEnabled) private var isEnabled

    /// Back-compat with the earlier `compact:` spelling.
    init(tint: Color = .accentColor, prominent: Bool = true, compact: Bool) {
        self.init(tint: tint, prominent: prominent, size: compact ? .compact : .regular)
    }

    init(tint: Color = .accentColor, prominent: Bool = true, size: Size = .regular) {
        self.tint = tint
        self.prominent = prominent
        self.size = size
    }

    private var font: Font {
        switch size {
        case .regular: return .body.weight(.medium)
        case .compact: return .callout.weight(.medium)
        case .mini:    return .caption2.weight(.medium)
        }
    }
    private var hPad: CGFloat { size == .regular ? 14 : (size == .compact ? 10 : 7) }
    private var vPad: CGFloat { size == .regular ? 6 : (size == .compact ? 4 : 2) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            // Button text is inviolable: one line, never wrapped or squashed
            // vertically. Horizontal stays flexible so full-width labels
            // (maxWidth: .infinity) still stretch across their row.
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary.opacity(0.16)),
                        in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1.0) : 0.4)
    }
}

extension ButtonStyle where Self == SolidButton {
    static var solid: SolidButton { SolidButton(prominent: true) }
    static var solidSecondary: SolidButton { SolidButton(prominent: false) }
    static var solidCompact: SolidButton { SolidButton(prominent: true, size: .compact) }
    static var solidSecondaryCompact: SolidButton { SolidButton(prominent: false, size: .compact) }
    static var solidMini: SolidButton { SolidButton(prominent: true, size: .mini) }
    static var solidSecondaryMini: SolidButton { SolidButton(prominent: false, size: .mini) }
}

/// Hero call-to-action: an interactive tinted Liquid Glass capsule (spec
/// section 5 "Hero CTA"). For welcome pages, onboarding, and promotional
/// buttons - not ordinary form controls. Falls back to a tinted material
/// capsule under macOS 26 via `liquidGlass`.
struct GlassCTAButton: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // Moderate glass-CTA metrics: a step up from SolidButton, but no
        // fixed minimum width - the old hero sizing (H22/V11, minWidth 168)
        // made the demo sheets' "Take me..." buttons read massive.
        configuration.label
            .font(.body.weight(.semibold))
            // Same inviolable-label rule as SolidButton: one line, no vertical
            // squash; horizontal stays flexible for full-width labels.
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .liquidGlass(in: Capsule(), tint: tint, interactive: true)
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.4)
    }
}

extension ButtonStyle where Self == GlassCTAButton {
    static var glassCTA: GlassCTAButton { GlassCTAButton() }
}

@main
struct InputConfig: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
                .environmentObject(appState.mappingEngine)
                .environmentObject(appState.eightBitDoDetector)
                .windowBackdrop()
                .reduceMotionFriendly()
                .appAccessibility()
                .onAppear {
                    #if DEBUG
                    _ = DebugMarketing.shared   // register marketing capture hooks
                    #endif
                    MenuBarController.shared.install(
                        presetStore: appState.presetStore,
                        mappingEngine: appState.mappingEngine,
                        controllerService: appState.controllerService
                    )
                    FrontmostAppWatcher.shared.install(
                        presetStore: appState.presetStore,
                        mappingEngine: appState.mappingEngine
                    )
                    // Apply the saved Dock-icon preference now that the window
                    // is up. Defaults to visible (registered in AppState.init).
                    AppState.applyDockIconVisible(
                        UserDefaults.standard.bool(forKey: "InputConfig.showDockIcon")
                    )
                }
        }
        .defaultSize(width: 1300, height: 750)
        .commands {
            // MARK: File menu - preset creation + quick file actions
            CommandGroup(after: .newItem) {
                Button("New Preset") {
                    _ = appState.presetStore.createPreset()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Duplicate Active Preset") {
                    if let active = appState.presetStore.presets.first(where: { $0.isActive }) {
                        _ = appState.presetStore.duplicatePreset(active)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Reveal Data Folder in Finder") {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let dataDir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dataDir])
                }
            }

            // MARK: View menu - sidebar + statistics + welcome
            CommandGroup(before: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                    )
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                Button("Show Statistics") {
                    NotificationCenter.default.post(name: .inputConfigShowStats, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            // MARK: Controller menu - new top-level menu for controller stuff
            CommandMenu("Controller") {
                Button("Refresh Connected Controllers") {
                    appState.controllerService.refreshControllers()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Activate / Deactivate Selected Preset") {
                    NotificationCenter.default.post(name: .inputConfigToggleActivePreset, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Button("Stop All Activity") {
                    appState.mappingEngine.stop()
                    appState.presetStore.deactivateAll()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Button("Calibrate Touchpad…") {
                    NotificationCenter.default.post(name: .inputConfigOpenTouchpadCalibration, object: nil)
                }

                Button("Calibrate Motion / Gyro…") {
                    NotificationCenter.default.post(name: .inputConfigOpenMotionCalibration, object: nil)
                }
            }

            // MARK: Help menu - guides + diagnostics
            CommandGroup(replacing: .help) {
                Button("InputConfig Help") {
                    HelpGuideWindowController.shared.show()
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Quick Start Tour") {
                    NotificationCenter.default.post(name: .inputConfigStartTutorial, object: nil)
                }

                Divider()

                Button("Support InputConfig...") {
                    TipJarWindowController.shared.show()
                }

                Divider()

                Button("Test Bench (Diagnostics)...") {
                    TestBenchWindowController.shared.show()
                }
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState.presetStore)
                .environmentObject(appState.controllerService)
                .environmentObject(appState.mappingEngine)
                .appAccessibility()
        }
    }
}

/// Switches presets automatically when the frontmost app changes. A preset
/// opts in by listing bundle identifiers in
/// `automation.autoActivateBundleIDs` (the "Auto-activate for apps" list in
/// the editor's Advanced Options), and the whole feature is gated by a
/// global Settings toggle so nothing moves without the user asking.
///
/// Sandbox-safe: NSWorkspace.didActivateApplicationNotification delivers the
/// activated app's bundle identifier with no extra entitlement; the same
/// observer pattern already drives the light-bar re-assert in
/// GameControllerService.
///
/// Restore behavior: the preset that was active before the first auto
/// switch is remembered, and switching to an app that matches no preset
/// brings it back (or deactivates, if nothing was active). A manual
/// activation in between clears the memory, so the watcher never fights
/// an explicit user choice.
@MainActor
final class FrontmostAppWatcher {
    static let shared = FrontmostAppWatcher()

    static let enabledDefaultsKey = "InputConfig.autoSwitch.enabled"

    private weak var presetStore: PresetStore?
    private weak var mappingEngine: MappingEngine?
    private var observer: NSObjectProtocol?
    /// What was active before the first auto switch, restored on leaving.
    private var autoSwitchedFromPresetID: UUID?
    /// The preset the watcher itself activated last; if the active preset
    /// differs, the user switched manually and the watcher backs off.
    private var lastAutoActivatedPresetID: UUID?

    private init() {}

    func install(presetStore: PresetStore, mappingEngine: MappingEngine) {
        guard observer == nil else { return }
        self.presetStore = presetStore
        self.mappingEngine = mappingEngine
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                self?.handleFrontmost(bundleID: bundleID)
            }
        }
    }

    private func handleFrontmost(bundleID: String?) {
        guard UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey),
              let bundleID,
              bundleID != Bundle.main.bundleIdentifier,
              let store = presetStore,
              let engine = mappingEngine else { return }

        if let match = store.presets.first(where: { preset in
            (preset.automation.autoActivateBundleIDs ?? []).contains(bundleID)
        }) {
            guard store.activePresetId != match.id else { return }
            // Remember what to come back to, but only when this is the
            // FIRST auto switch of a run; hopping between two matched apps
            // keeps the original restore point.
            if lastAutoActivatedPresetID == nil || store.activePresetId != lastAutoActivatedPresetID {
                autoSwitchedFromPresetID = store.activePresetId
            }
            engine.stop()
            store.activatePreset(match)
            engine.start(with: match)
            lastAutoActivatedPresetID = match.id
        } else if let lastAuto = lastAutoActivatedPresetID {
            // Only unwind an ACTIVE auto switch; if the user changed presets
            // manually since, leave their choice alone.
            guard store.activePresetId == lastAuto else {
                lastAutoActivatedPresetID = nil
                autoSwitchedFromPresetID = nil
                return
            }
            if let backID = autoSwitchedFromPresetID,
               let back = store.presets.first(where: { $0.id == backID }) {
                engine.stop()
                store.activatePreset(back)
                engine.start(with: back)
            } else {
                engine.stop()
                store.deactivateAll()
            }
            lastAutoActivatedPresetID = nil
            autoSwitchedFromPresetID = nil
        }
    }
}
