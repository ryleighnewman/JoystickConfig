import AppKit
import Combine
import SwiftUI

/// AppKit-backed menu bar status item. Replaces SwiftUI's MenuBarExtra,
/// which couldn't be hidden at runtime without triggering an infinite
/// scenesDidChange loop on macOS 26. The status item opens a SwiftUI
/// frosted popover styled after YapToText's menu bar surface, carrying
/// EVERY feature the classic NSMenu had: active-session header with tag +
/// binding summary, engine + CPU/RAM status, connected controllers with
/// battery, the grouped preset library, and all app actions.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {

    static let shared = MenuBarController()

    static let defaultsKey = "InputConfig.showMenuBarIcon"

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var presetStore: PresetStore?
    private weak var mappingEngine: MappingEngine?
    private weak var controllerService: GameControllerService?
    private var cancellables: Set<AnyCancellable> = []
    /// Watches the menu bar's light/dark appearance so the running (green)
    /// glyph can switch shades the way template menu bar icons auto-invert.
    private var appearanceObservation: NSKeyValueObservation?

    private override init() {
        super.init()
    }

    /// Create the status item and seed visibility from defaults. Called once
    /// from app startup with live references to the stores the popover reads.
    func install(presetStore: PresetStore, mappingEngine: MappingEngine,
                 controllerService: GameControllerService? = nil) {
        guard statusItem == nil else { return }
        self.presetStore = presetStore
        self.mappingEngine = mappingEngine
        self.controllerService = controllerService

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            // Rebuild the glyph whenever the menu bar flips light/dark (a
            // light wallpaper or Light Mode makes the bar light) so the green
            // running-state icon deepens on a light bar the way template
            // menu bar icons auto-invert.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                self?.refreshMenuBarImage()
            }
        }
        statusItem = item
        refreshMenuBarImage()

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        popover = pop

        let visible = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
        item.isVisible = visible

        // Live cue: the glyph is a normal template icon while idle (adaptive
        // to the menu bar's light/dark) and swaps to a solid green glyph while
        // a preset is running. A green *template tint* rendered black on some
        // menu bars, so we bake a real green, non-template image instead.
        mappingEngine.$isRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuBarImage()
            }
            .store(in: &cancellables)

        // Keep the global hotkey working when the main window is closed.
        // ContentView owns the toggle while a main-capable window exists
        // (its path applies calibration gating); with every window closed,
        // nothing received the notification and the Settings promise
        // ("works anywhere, even while another app is in front") broke in
        // exactly the headless scenario it exists for.
        NotificationCenter.default.publisher(for: GlobalHotKeyService.toggleNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      let presetStore = self.presetStore,
                      let mappingEngine = self.mappingEngine else { return }
                let windowAlive = NSApp.windows.contains {
                    $0.canBecomeMain && !($0 is NSPanel) && ($0.isVisible || $0.isMiniaturized)
                }
                if windowAlive { return }
                if presetStore.presets.contains(where: { $0.isActive }) {
                    mappingEngine.stop()
                    presetStore.deactivateAll()
                } else {
                    let target = presetStore.lastActivatedPresetId
                        .flatMap { id in presetStore.presets.first(where: { $0.id == id }) }
                        ?? presetStore.presets.first(where: { $0.isRunnable })
                    if let target {
                        mappingEngine.stop()
                        presetStore.activatePreset(target)
                        mappingEngine.start(with: target)
                    }
                }
            }
            .store(in: &cancellables)

        #if DEBUG
        // Marketing / QA: open (or close) the popover from the shell so its
        // real translucent panel can be captured. DEBUG-only.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("inputconfig.debug.menubar"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.debugTogglePopover()
        }
        #endif
    }

    #if DEBUG
    /// Open/close the menu bar popover anchored to the status item, without a
    /// real click. Used by the marketing capture pipeline.
    private func debugTogglePopover() {
        guard let button = statusItem?.button else { return }
        togglePopover(button)
    }
    #endif

    /// Rebuild the status item glyph for the current running state AND the
    /// current menu bar appearance. Call whenever either changes.
    private func refreshMenuBarImage() {
        guard let button = statusItem?.button else { return }
        let running = mappingEngine?.isRunning ?? false
        button.image = Self.makeMenuBarImage(running: running,
                                             appearance: button.effectiveAppearance)
    }

    /// The menu bar glyph (the app's own controller artwork). Idle: template
    /// (system tints it for the menu bar). Running: a solid green,
    /// non-template copy so "mappings on" reads at a glance. Because a colored
    /// (non-template) image does not auto-invert, the green shade is chosen
    /// from the menu bar's light/dark appearance: a bright system green on a
    /// dark bar, a deeper forest green on a light bar, so it stays legible
    /// either way, like the way macOS menu bar icons adapt.
    private static func makeMenuBarImage(running: Bool,
                                         appearance: NSAppearance) -> NSImage? {
        let size = NSSize(width: 26, height: 17.4)
        guard let base = NSImage(named: "ControllerGlyph") else { return nil }
        if running {
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let fill: NSColor = isDark
                ? NSColor.systemGreen
                : NSColor(srgbRed: 0.11, green: 0.44, blue: 0.17, alpha: 1.0)
            let green = NSImage(size: size, flipped: false) { rect in
                fill.setFill()
                rect.fill()
                base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
                return true
            }
            green.isTemplate = false
            green.accessibilityDescription = "InputConfig (running)"
            return green
        } else {
            let template = base.copy() as? NSImage
            template?.isTemplate = true
            template?.size = size
            template?.accessibilityDescription = "InputConfig"
            return template
        }
    }

    /// Show or hide the status item without removing it. Safe to call from
    /// SwiftUI .onChange handlers.
    func setVisible(_ visible: Bool) {
        statusItem?.isVisible = visible
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
            return
        }
        guard let presetStore, let mappingEngine else { return }

        // Keep the CPU/RAM readout live while the popover is open.
        SystemStatsService.shared.retain()

        let root = MenuBarPopoverView(
            presetStore: presetStore,
            mappingEngine: mappingEngine,
            controllerService: controllerService,
            onToggle: { [weak self] preset in self?.toggle(preset) },
            onNewPreset: { [weak self] in self?.dismissThen { self?.newPreset() } },
            onSmartMaker: { [weak self] in self?.dismissThen { self?.openSmartMaker() } },
            onStatistics: { [weak self] in self?.dismissThen { self?.openStatistics() } },
            onOpen: { [weak self] in self?.dismissThen { self?.openMainWindow() } },
            onSettings: { [weak self] in self?.dismissThen { self?.openSettings() } },
            onHelp: { [weak self] in self?.dismissThen { self?.openHelpGuides() } },
            onSupport: { [weak self] in self?.dismissThen { self?.openTipJar() } },
            onQuit: { [weak self] in self?.quitApp() }
        ).appAccessibility()
        let hosting = NSHostingController(rootView: root.reduceMotionFriendly())
        hosting.sizingOptions = [.preferredContentSize]
        pop.contentViewController = hosting
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Make the popover key so its SwiftUI buttons receive clicks.
        pop.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        SystemStatsService.shared.release()
    }

    private func dismissThen(_ action: @escaping () -> Void) {
        popover?.performClose(nil)
        action()
    }

    /// Toggle a preset from the popover, then close it (like picking a menu item).
    private func toggle(_ preset: Preset) {
        guard let mappingEngine, let presetStore else { return }
        if preset.isActive {
            mappingEngine.stop()
            presetStore.deactivateAll()
        } else if preset.isRunnable {
            mappingEngine.stop()
            presetStore.activatePreset(preset)
            mappingEngine.start(with: preset)
        }
        popover?.performClose(nil)
    }

    // MARK: - App actions (controller-triggered runtime control)

    /// Perform an internal app action fired by a binding's App Action output.
    /// Lives here because this controller already holds app-lifetime
    /// references to the store and engine and performs the same activation
    /// work for menu clicks, so the feature works with the window closed.
    func performAppAction(_ kind: AppActionKind, targetPresetID: UUID?) {
        guard let store = presetStore, let engine = mappingEngine else { return }
        switch kind {
        case .activatePreset:
            guard let id = targetPresetID,
                  let preset = store.presets.first(where: { $0.id == id }),
                  preset.isRunnable,
                  store.activePresetId != preset.id else { return }
            engine.stop()
            store.activatePreset(preset)
            engine.start(with: preset)
        case .nextPreset, .previousPreset:
            let usable = store.presets.filter { $0.isRunnable }
            guard !usable.isEmpty else { return }
            let step = (kind == .nextPreset) ? 1 : -1
            let nextIndex: Int
            if let current = usable.firstIndex(where: { $0.id == store.activePresetId }) {
                nextIndex = (current + step + usable.count) % usable.count
            } else {
                nextIndex = (kind == .nextPreset) ? 0 : usable.count - 1
            }
            let preset = usable[nextIndex]
            engine.stop()
            store.activatePreset(preset)
            engine.start(with: preset)
        case .deactivate:
            engine.stop()
            store.deactivateAll()
        case .togglePauseOutputs:
            engine.outputsPaused.toggle()
        }
    }

    // MARK: - Window actions

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Prefer a real main-capable window. The old predicate
        // (title match OR non-nil contentView) was true for nearly every
        // window, including panels and the status item's own window, so
        // it raised an arbitrary first match; and with every window
        // closed (normal for a menu bar app) it silently did nothing.
        if let visible = NSApp.windows.first(where: {
            $0.canBecomeMain && !($0 is NSPanel) && ($0.isVisible || $0.isMiniaturized)
        }) {
            if visible.isMiniaturized { visible.deminiaturize(nil) }
            visible.makeKeyAndOrderFront(nil)
            return
        }
        if let hidden = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            hidden.makeKeyAndOrderFront(nil)
            return
        }
        // No main window exists anymore: drive the same reopen path a
        // Dock-icon click uses so SwiftUI recreates the WindowGroup window.
        _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func openHelpGuides() {
        NSApp.activate(ignoringOtherApps: true)
        HelpGuideWindowController.shared.show()
    }

    /// Bring the main window forward and open the Statistics sheet.
    @objc private func openStatistics() {
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .inputConfigShowStats, object: nil)
        }
    }

    /// Bring the main window forward and open the Smart Preset Maker.
    @objc private func openSmartMaker() {
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .inputConfigOpenSmartMaker, object: nil)
        }
    }

    /// Create a fresh preset and bring the app forward to edit it.
    @objc private func newPreset() {
        _ = presetStore?.createPreset()
        openMainWindow()
    }

    @objc private func openTipJar() {
        NSApp.activate(ignoringOtherApps: true)
        TipJarWindowController.shared.show()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Popover UI (YapToText menu bar language)

/// The menu bar popover, a close replica of YapToText's so the family shares
/// one menu-bar language: the SAME frosted window container glass, the SAME
/// spacing (VStack spacing 10, padding 12, width 320), the SAME component
/// tokens (translucent header action pill, capsule selector pills, innerWell
/// square quick-actions, bare-icon footer). Only the content differs, mapped
/// onto InputConfig's domain: the Mode/Input pills become Preset/Controller,
/// the record pill becomes Start/Stop, and Recent becomes engine Status.
private struct MenuBarPopoverView: View {
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var mappingEngine: MappingEngine
    weak var controllerService: GameControllerService?
    let onToggle: (Preset) -> Void
    let onNewPreset: () -> Void
    let onSmartMaker: () -> Void
    let onStatistics: () -> Void
    let onOpen: () -> Void
    let onSettings: () -> Void
    let onHelp: () -> Void
    let onSupport: () -> Void
    let onQuit: () -> Void

    @ObservedObject private var stats = SystemStatsService.shared
    private var activePreset: Preset? { presetStore.presets.first { $0.isActive } }
    private var running: Bool { mappingEngine.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            selectorRow
            quickActions
            Divider()
            statusSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .symbolRenderingMode(.hierarchical)
        .focusEffectDisabled()
        // THE glass: the same window-container frosted material YapToText uses,
        // which fills the whole popover window (not just behind the content the
        // way a plain .background does), so the liquid-glass look matches.
        .menuBarGlass()
    }

    // MARK: Header - brand + the one action (Start/Stop), like the record pill

    private var header: some View {
        HStack(spacing: 8) {
            ControllerGlyph(height: 26)
                .iconTint(running ? .green : .green)
                .accessibilityHidden(true)
            Text("InputConfig").font(.headline)
            // The running build, right where you look while testing - text
            // only, no button. Same placement as YapToText's menu bar.
            Text(Changelog.currentVersion)
                .font(.caption).monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            Spacer()
            enginePill
        }
    }

    @ViewBuilder private var enginePill: some View {
        if let active = activePreset {
            Button { onToggle(active) } label: {
                pill(icon: "stop.fill", text: "Stop", tint: .icStop)
            }
            .buttonStyle(.plain).help("Stop \(active.name)")
            .accessibilityLabel("Stop the running preset")
        } else {
            let target = firstRunnable
            Button { if let t = target { onToggle(t) } } label: {
                pill(icon: "play.fill", text: "Start", tint: .green)
            }
            .buttonStyle(.plain).disabled(target == nil).opacity(target == nil ? 0.5 : 1)
            .help(target.map { "Start \($0.name)" } ?? "Add a preset first")
            .accessibilityLabel("Start the last preset")
        }
    }

    private func pill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(tint.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
        .contentShape(Capsule())
    }

    private var firstRunnable: Preset? {
        presetStore.lastActivatedPresetId
            .flatMap { id in presetStore.presets.first { $0.id == id && $0.isRunnable } }
            ?? presetStore.presets.first { $0.isRunnable }
    }

    // MARK: Selector row - two capsule pills (Preset + Controller), like Mode + Input

    private var selectorRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(presetStore.groups.sorted { $0.sortOrder < $1.sortOrder }) { group in
                    let ps = presetStore.presets(in: group.id)
                    if !ps.isEmpty { Section(group.name) { ForEach(ps) { presetMenuButton($0) } } }
                }
                let ungrouped = presetStore.presets(in: nil)
                if !ungrouped.isEmpty {
                    Section(presetStore.groups.isEmpty ? "Presets" : "Ungrouped") {
                        ForEach(ungrouped) { presetMenuButton($0) }
                    }
                }
            } label: {
                selectorLabel("Preset", icon: "slider.horizontal.3", value: activePreset?.name ?? "No preset")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("Switch the active preset")

            Menu {
                if let svc = controllerService, !svc.controllerDetails.isEmpty {
                    Section("Connected") {
                        ForEach(svc.controllerDetails.keys.sorted(), id: \.self) { slot in
                            if let info = svc.controllerDetails[slot] {
                                Button {} label: {
                                    if info.hasBattery, let level = info.batteryLevel {
                                        Label("\(info.name)  \(Int(level * 100))%", systemImage: "gamecontroller")
                                    } else {
                                        Label(info.name, systemImage: "gamecontroller")
                                    }
                                }.disabled(true)
                            }
                        }
                    }
                } else {
                    Button("No controller connected") {}.disabled(true)
                }
            } label: {
                selectorLabel("Controller", icon: "gamecontroller.fill", value: primaryControllerName)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("Connected controllers")
        }
    }

    @ViewBuilder private func presetMenuButton(_ preset: Preset) -> some View {
        Button { onToggle(preset) } label: {
            Label(preset.name,
                  systemImage: preset.isActive ? "checkmark"
                      : (preset.isRunnable ? "circle" : "circle.dashed"))
        }
        .disabled(!preset.isRunnable && !preset.isActive)
    }

    private var primaryControllerName: String {
        guard let d = controllerService?.controllerDetails, !d.isEmpty else { return "No controller" }
        if d.count == 1, let info = d.first?.value { return info.name }
        return "\(d.count) controllers"
    }

    /// The capsule selector pill, identical to YapToText's selectorLabel token.
    private func selectorLabel(_ label: String, icon: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).iconTint(.green)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(label): \(value)")
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
    }

    // MARK: Quick actions - innerWell square buttons, identical token to YapToText

    private var quickActions: some View {
        HStack(spacing: 8) {
            squareButton("New Preset", "plus.rectangle.on.rectangle", action: onNewPreset)
            squareButton("Smart Preset", "wand.and.stars", action: onSmartMaker)
            squareButton("Statistics", "chart.line.uptrend.xyaxis", action: onStatistics)
        }
    }

    private func squareButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18)).iconTint(.green)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 62)
            .innerWell(radius: 11)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).help(title)
    }

    // MARK: Status - the "Recent" slot, showing engine state (InputConfig domain)

    private var statusSection: some View {
        let paused = mappingEngine.outputsPaused
        let dot: Color = running ? (paused ? .orange : .green) : .secondary
        let label = running
            ? (paused ? "Outputs paused" : "Engine running \(mappingEngine.currentPollHz) Hz")
            : "Engine idle"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Status").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 6) {
                Circle().fill(dot.opacity(0.85)).frame(width: 7, height: 7)
                Text(label).font(.caption)
                Spacer(minLength: 8)
                Text(String(format: "CPU %.0f%%  \u{00B7}  RAM %.0f MB",
                            stats.current.smoothedCpuPercent,
                            Double(stats.current.residentMemoryBytes) / 1_048_576.0))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Footer - four bare icons: meta left, go-to-app right (YapToText layout)

    private var footer: some View {
        HStack(spacing: 16) {
            MenuFooterIcon(symbol: "power", help: "Quit InputConfig", action: onQuit)
            MenuFooterIcon(symbol: "heart.fill", help: "Support InputConfig", tint: .pink, action: onSupport)
            Spacer()
            MenuFooterIcon(symbol: "macwindow", help: "Open InputConfig", action: onOpen)
            MenuFooterIcon(symbol: "gearshape", help: "Settings", action: onSettings)
        }
        .font(.body)
    }
}

private extension View {
    /// The family menu-bar window glass. On macOS 15+ this is the true
    /// window-container frosted material (fills the whole popover window,
    /// matching YapToText); on the macOS 14 App Store floor it falls back to a
    /// plain material background behind the content.
    @ViewBuilder func menuBarGlass() -> some View {
        if AppA11y.reduceTransparency {
            background(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 15.0, *) {
            containerBackground(.ultraThinMaterial, for: .window)
        } else {
            background(.ultraThinMaterial)
        }
    }
}

/// A footer icon button: the shared hover fill and, for colored icons, the
/// shared iconTint transparency. Matches YapToText's footer icon language.
private struct MenuFooterIcon: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void

    // Bare icon button, identical to YapToText's footer buttons: no padding,
    // no hover fill, no enlarged hit shape. This is what makes the glyphs sit
    // flush at the 12pt container margin with a true 16pt gap (the padded
    // version inflated them and pushed the corner icons inward).
    var body: some View {
        Button(action: action) { glyph }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }

    @ViewBuilder private var glyph: some View {
        if let tint {
            Image(systemName: symbol).iconTint(tint)
        } else {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}
