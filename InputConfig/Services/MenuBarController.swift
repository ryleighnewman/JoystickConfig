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
            button.image = Self.makeMenuBarImage(running: mappingEngine.isRunning)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

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
            .sink { [weak self] running in
                self?.statusItem?.button?.image = Self.makeMenuBarImage(running: running)
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
    }

    /// The menu bar glyph (the app's own controller artwork). Idle: template
    /// (system tints it for the menu bar). Running: a solid green,
    /// non-template copy so "mappings on" reads at a glance.
    private static func makeMenuBarImage(running: Bool) -> NSImage? {
        let size = NSSize(width: 26, height: 17.4)
        guard let base = NSImage(named: "ControllerGlyph") else { return nil }
        if running {
            let green = NSImage(size: size, flipped: false) { rect in
                NSColor.systemGreen.setFill()
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
            onOpen: { [weak self] in self?.dismissThen { self?.openMainWindow() } },
            onSettings: { [weak self] in self?.dismissThen { self?.openSettings() } },
            onHelp: { [weak self] in self?.dismissThen { self?.openHelpGuides() } },
            onTestBench: { [weak self] in self?.dismissThen { self?.openTestBench() } },
            onSupport: { [weak self] in self?.dismissThen { self?.openTipJar() } },
            onQuit: { [weak self] in self?.quitApp() }
        )
        let hosting = NSHostingController(rootView: root)
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

    @objc private func openTestBench() {
        NSApp.activate(ignoringOtherApps: true)
        TestBenchWindowController.shared.show()
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

/// The menu bar's SwiftUI content. Frosted panel, flat tinted glyph header,
/// quiet status strip, controllers + grouped presets, bare-icon footer.
/// Feature-parity with the old NSMenu: nothing was dropped.
private struct MenuBarPopoverView: View {
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var mappingEngine: MappingEngine
    weak var controllerService: GameControllerService?
    let onToggle: (Preset) -> Void
    let onOpen: () -> Void
    let onSettings: () -> Void
    let onHelp: () -> Void
    let onTestBench: () -> Void
    let onSupport: () -> Void
    let onQuit: () -> Void

    @ObservedObject private var stats = SystemStatsService.shared

    private var activePreset: Preset? { presetStore.presets.first { $0.isActive } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusStrip
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    controllersSection
                    presetsSection
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.s)
            }
            .frame(maxHeight: 320)
            Divider()
            footer
        }
        .frame(width: 320)
        // The popover is a separate hosting controller outside ContentView's
        // environment, so hierarchical rendering is set explicitly here.
        .symbolRenderingMode(.hierarchical)
        // The "water" panel: same frosted material as YapToText's menu bar.
        .background(.ultraThinMaterial)
    }

    // MARK: Header

    private var header: some View {
        let running = activePreset != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ControllerGlyph(height: 26)
                    .iconTint(running ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("InputConfig")
                        .font(.headline)
                    Text(activePreset?.name ?? "No preset active")
                        .font(.caption)
                        .foregroundStyle(running ? AnyShapeStyle(Color.green.opacity(0.85))
                                                 : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer()
                if activePreset != nil {
                    Button("Stop") { if let a = activePreset { onToggle(a) } }
                        .buttonStyle(SolidButton(tint: .red, size: .compact))
                        .accessibilityLabel("Deactivate the running preset")
                }
            }
            // Tag + binding summary for the active preset (feature parity
            // with the old menu's session header).
            if let active = activePreset {
                VStack(alignment: .leading, spacing: 1) {
                    if !active.tag.isEmpty {
                        Text(active.tag)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    let total = active.joysticks.reduce(0) { $0 + $1.bindings.count }
                    Text("\(total) \(total == 1 ? "binding" : "bindings") across \(active.joysticks.count) \(active.joysticks.count == 1 ? "slot" : "slots")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 34)
            }
        }
        .padding(Metrics.cardPad)
    }

    // MARK: Status strip

    private var statusStrip: some View {
        let running = mappingEngine.isRunning
        let paused = mappingEngine.outputsPaused
        let dot: Color = running ? (paused ? .orange : .green) : .secondary
        let label = running
            ? (paused ? "Outputs paused (editor open)" : "Engine running \(mappingEngine.currentPollHz) Hz")
            : "Engine idle"
        return HStack(spacing: 6) {
            Circle().fill(dot.opacity(0.85)).frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(String(format: "CPU %.1f%%  \u{00B7}  RAM %.0f MB",
                        stats.current.smoothedCpuPercent,
                        Double(stats.current.residentMemoryBytes) / 1_048_576.0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Metrics.cardPad)
        .padding(.vertical, 8)
    }

    // MARK: Controllers

    @ViewBuilder
    private var controllersSection: some View {
        sectionHeader("Controllers")
        if let svc = controllerService, !svc.controllerDetails.isEmpty {
            ForEach(svc.controllerDetails.keys.sorted(), id: \.self) { slot in
                if let info = svc.controllerDetails[slot] {
                    HStack(spacing: 8) {
                        ControllerGlyph(height: 11)
                            .foregroundStyle(.secondary)
                        Text(info.name)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if info.hasBattery, let level = info.batteryLevel {
                            Text("\(Int(level * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 3)
                }
            }
        } else {
            Text("None connected")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 3)
        }
    }

    // MARK: Presets

    @ViewBuilder
    private var presetsSection: some View {
        sectionHeader("Presets")
        ForEach(presetStore.groups.sorted { $0.sortOrder < $1.sortOrder }) { group in
            let ps = presetStore.presets(in: group.id)
            if !ps.isEmpty {
                groupLabel(group.name)
                ForEach(ps) { presetRow($0) }
            }
        }
        let ungrouped = presetStore.presets(in: nil)
        if !ungrouped.isEmpty {
            groupLabel(presetStore.groups.isEmpty ? "" : "Ungrouped")
            ForEach(ungrouped) { presetRow($0) }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Space.s)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func groupLabel(_ title: String) -> some View {
        if !title.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.s)
            .padding(.top, 6)
            .padding(.bottom, 1)
        }
    }

    private func presetRow(_ preset: Preset) -> some View {
        MenuHoverRow(active: preset.isActive, enabled: preset.isRunnable) {
            onToggle(preset)
        } label: {
            HStack(spacing: Space.s) {
                Text(preset.name)
                    .font(.subheadline)
                    .foregroundStyle(preset.isRunnable ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if preset.isActive {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .iconTint(.green)
                }
            }
        }
        .help(preset.isRunnable ? "" : "No bindings yet. Open InputConfig to add some.")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            MenuFooterIcon(symbol: "macwindow", help: "Open InputConfig", action: onOpen)
            MenuFooterIcon(symbol: "gearshape", help: "Settings", action: onSettings)
            MenuFooterIcon(symbol: "questionmark.circle", help: "Help Guides", action: onHelp)
            MenuFooterIcon(symbol: "wrench.and.screwdriver", help: "Test Bench", action: onTestBench)
            Spacer()
            MenuFooterIcon(symbol: "heart.fill", help: "Support InputConfig", tint: .pink, action: onSupport)
            MenuFooterIcon(symbol: "power", help: "Quit InputConfig", action: onQuit)
        }
        .font(.body)
        .padding(Metrics.cardPad)
    }
}

/// A full-width preset row with hover + active tint, kept as its own view so
/// the hover @State works (a ButtonStyle can't hold state).
private struct MenuHoverRow<Label: View>: View {
    /// The active-preset row tint (a named token, not an inline literal).
    private static var activeFill: Color { Color.green.opacity(0.14) }

    let active: Bool
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: { if enabled { action() } }) {
            label()
                .padding(.horizontal, Space.s).padding(.vertical, Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                        .fill(active ? Self.activeFill : Color.clear)
                )
                .hoverFill(hovering && !active)
                .contentShape(RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && enabled }
    }
}

/// A footer icon button: the shared hover fill and, for colored icons, the
/// shared iconTint transparency.
private struct MenuFooterIcon: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            glyph
                .padding(Space.s)
                .hoverFill(hovering)
                .contentShape(RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
