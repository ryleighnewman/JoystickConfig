#if os(macOS)
import SwiftUI
import GameController

struct SettingsView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine

    /// Which tab is currently visible. Replaces SwiftUI's `TabView` because
    /// `TabView`'s tab bar clips against a sheet's rounded top corners on
    /// macOS, leaving the tab pills half-cut. A plain segmented Picker sits
    /// safely inside the sheet's content area.
    @State private var selectedTab: SettingsTab = .general

    /// Mirrors the same `@AppStorage` key used by the main app scene so
    /// flipping this toggle immediately hides or shows the menu bar icon.
    @AppStorage("InputConfig.showMenuBarIcon") private var showMenuBarIcon = true
    /// Controls the Dock icon (activation policy). Paired with the menu bar
    /// icon by a see-saw rule so at least one is always visible.
    @AppStorage("InputConfig.showDockIcon") private var showDockIcon = true
    /// Mirrors the key ContentView reads to pin the developer activity log
    /// under the detail pane. Off by default so the shipping UI stays clean.
    @AppStorage("InputConfig.showDebugLog") private var showDebugLog = false
    /// Drives the system-wide "toggle most recent preset" hotkey. Same key
    /// AppState reads at launch to decide whether to register the chord.
    @AppStorage(GlobalHotKeyService.enabledDefaultsKey) private var globalHotkeyEnabled = false

    @AppStorage(FrontmostAppWatcher.enabledDefaultsKey) private var autoSwitchEnabled = false

    /// Controller poll rate in Hz. Mirrors the `pollHz` UserDefaults key
    /// that `MappingEngine.start(with:)` reads when scheduling its poll
    /// timer. Stored as Int (60/120/180/240). Changes take effect on the
    /// next preset activation.
    @AppStorage("InputConfig.pollHz") private var pollHz: Int = 120

    /// When true, the engine reads pollHzOnAC vs pollHzOnBattery
    /// depending on the Mac's current power source and re-installs the
    /// poll timer the moment that source changes. Defaults ON (also
    /// registered in AppState) so polling adapts to power out of the box.
    @AppStorage("InputConfig.autoPollHzByPower") private var autoPollByPower: Bool = true
    @AppStorage("InputConfig.pollHzOnAC") private var pollHzOnAC: Int = 120
    @AppStorage("InputConfig.pollHzOnBattery") private var pollHzOnBattery: Int = 60

    /// Live references to the reliability services so the freeze
    /// detection toggle and "last freeze" timestamp update in place.
    @ObservedObject private var crashRecovery = CrashRecoveryService.shared
    @ObservedObject private var freezeWatchdog = FreezeWatchdogService.shared
    @ObservedObject private var accessibility = AccessibilityPermissionService.shared
    /// The live press log, observed here (not via the controller service) so
    /// its per-press updates re-render only this sheet, never the root window.
    @ObservedObject private var pressLog = PhysicalPressLogStore.shared
    @State private var showingCursorRegions = false
    @State private var showingStickRegions = false

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case advanced = "Advanced"
        case controllers = "Controllers"
        case about = "About"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .general: return "gear"
            case .advanced: return "slider.horizontal.3"
            case .controllers: return "gamecontroller"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector. Pinned at the top of the sheet, tucked safely
            // below the rounded corner via padding.
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label { Text(tab.rawValue) } icon: {
                        IconView(name: tab.systemImage, glyphHeight: 11)
                    }
                    .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Settings section")
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch selectedTab {
                case .general: generalTab
                case .advanced: advancedTab
                case .controllers: controllersTab
                case .about: aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingCursorRegions) {
            CursorRegionsView()
                .glassBackground()
        }
        .sheet(isPresented: $showingStickRegions) {
            StickRegionsView()
                .glassBackground()
        }
        // macOS Form needs more room. With sections containing descriptions
        // and toggles, 500 px clips the labels and right column. Widening
        // keeps multi-line descriptions readable.
        .frame(width: 620, height: 520)
    }

    // MARK: - General

    private var generalTab: some View {
        // Use plain VStack with section headers instead of Form so the
        // sections render left-aligned and full-width on macOS rather than
        // getting squeezed into Form's narrow two-column layout.
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Accessibility") {
                    HStack(spacing: 8) {
                        Image(systemName: accessibility.isTrusted ? "circle.fill" : "exclamationmark.triangle.fill")
                            .font(accessibility.isTrusted ? .system(size: 9) : .body)
                            .foregroundStyle(accessibility.isTrusted ? .green : .orange)
                            .accessibilityHidden(true)
                        Text(accessibility.isTrusted ? "Accessibility access granted" : "Accessibility access not granted")
                            .font(.callout.weight(.medium))
                        Spacer()
                    }
                    .onAppear { accessibility.refresh() }

                    Text("InputConfig uses macOS Accessibility to send the keyboard and mouse actions you map to your controller. That is what lets a game controller operate macOS and your apps. It is used only to perform the mappings you set up. If you bind your Mac keyboard or mouse as an input source, the app reads those events solely to trigger your mappings; nothing is ever logged or sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !accessibility.isTrusted {
                        HStack(spacing: 8) {
                            Button("Grant Access…") { accessibility.requestAccess() }
                                .buttonStyle(.solidCompact)
                            Button("Open Accessibility Settings") { accessibility.openSystemSettings() }
                                .buttonStyle(.solidSecondaryCompact)
                        }
                        Text("Click Grant Access, then turn on InputConfig under System Settings, Privacy and Security, Accessibility. This updates automatically once you do.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section(title: "Startup") {
                    LaunchAtLoginToggleView()
                }

                section(title: "Dock & Menu Bar") {
                    Toggle("Show Dock icon", isOn: $showDockIcon)
                        .onChange(of: showDockIcon) { _, newValue in
                            // See-saw: turning one off while the other is
                            // already off pops the other back on, so InputConfig
                            // is never left with no way to reopen it.
                            if !newValue && !showMenuBarIcon {
                                showMenuBarIcon = true
                                MenuBarController.shared.setVisible(true)
                            }
                            AppState.applyDockIconVisible(newValue)
                        }

                    Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                        .onChange(of: showMenuBarIcon) { _, newValue in
                            if !newValue && !showDockIcon {
                                showDockIcon = true
                                AppState.applyDockIconVisible(true)
                            }
                            MenuBarController.shared.setVisible(newValue)
                        }

                    Text("Keep at least one of these on so you can always reach InputConfig. Hiding the Dock icon makes it a menu bar-only app (no Dock icon, no top menu bar); hiding the menu bar icon keeps it in the Dock. Turning one off while the other is already off switches the other back on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Keyboard Shortcut") {
                    Toggle("Universal shortcut to toggle the most recent preset",
                           isOn: $globalHotkeyEnabled)
                        .onChange(of: globalHotkeyEnabled) { _, on in
                            if on {
                                // Registration can fail when another app owns
                                // the chord; snap the switch back so Settings
                                // never shows a hotkey that is not live.
                                if !GlobalHotKeyService.shared.enable() {
                                    globalHotkeyEnabled = false
                                }
                            } else {
                                GlobalHotKeyService.shared.disable()
                            }
                        }
                    Text("Press \(GlobalHotKeyService.shared.shortcutDescription) anywhere to turn your most recently used preset on or off, even while another app is in front. Works system-wide and needs no extra permission. If another app already uses this shortcut, the switch turns itself back off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Advanced

    /// Advanced settings split out of General so the General tab stays short:
    /// automation, reliability/diagnostics, polling, system stats, the global
    /// gaming defaults, and data management.
    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Automatic Preset Switching") {
                    Toggle("Switch presets when the front app changes",
                           isOn: $autoSwitchEnabled)
                    Text("Presets can list apps in their Automation & Gaming Utilities panel; when one of those apps comes to the front, its preset activates by itself, and your previous preset comes back when you leave. Nothing switches unless a preset opts in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Reliability") {
                    Toggle("Restore active preset after a crash",
                           isOn: $crashRecovery.sessionRestoreEnabled)
                    Text("If the app exits unexpectedly, the next launch will re-activate the preset that was active before the crash. If a second crash happens within 90 seconds, recovery is skipped so a bad preset can't trap you in a restart loop. Force quitting from Activity Monitor behaves the same as a crash: your last active preset will come back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Detect freezes and save diagnostics",
                           isOn: $freezeWatchdog.enabled)
                    Text("A background watchdog pings the main thread once a second. If the app stops responding for more than 15 seconds the freeze is logged and your active preset is force-saved, so even if you have to force quit while frozen, the next launch will restore it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        if let when = crashRecovery.lastFreezeAt {
                            Text("Last freeze detected: \(when.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Last freeze detected: never")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Toggle("Show developer activity log", isOn: $showDebugLog)
                    Text("Pins a live log of controller and mapping activity to the bottom of the main window. Handy while troubleshooting; off by default so the window stays clean.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(title: "Polling Rate") {
                    Toggle(isOn: $autoPollByPower) {
                        Label("Auto-switch on power source",
                              systemImage: "battery.100.bolt")
                    }
                    .onChange(of: autoPollByPower) { _, _ in
                        mappingEngine.applyPollRate()
                    }

                    if autoPollByPower {
                        HStack(spacing: 8) {
                            Image(systemName: "powerplug.fill")
                                .foregroundStyle(.green)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            Picker("On power adapter", selection: $pollHzOnAC) {
                                Text("60 Hz").tag(60)
                                Text("120 Hz").tag(120)
                                Text("180 Hz").tag(180)
                                Text("240 Hz").tag(240)
                            }
                            .pickerStyle(.menu)
                            .onChange(of: pollHzOnAC) { _, _ in mappingEngine.applyPollRate() }
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "battery.50")
                                .foregroundStyle(.orange)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            Picker("On battery", selection: $pollHzOnBattery) {
                                Text("60 Hz").tag(60)
                                Text("120 Hz").tag(120)
                                Text("180 Hz").tag(180)
                                Text("240 Hz").tag(240)
                            }
                            .pickerStyle(.menu)
                            .onChange(of: pollHzOnBattery) { _, _ in mappingEngine.applyPollRate() }
                        }
                        Text("The engine switches between these rates the moment macOS reports a power-source change. Pick a lower rate for battery to stretch session time without restarting.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Controller poll rate", selection: $pollHz) {
                            Text("60 Hz - power saver").tag(60)
                            Text("120 Hz - default").tag(120)
                            Text("180 Hz - high precision").tag(180)
                            Text("240 Hz - maximum").tag(240)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: pollHz) { _, _ in
                            // Live-apply: rebuild the poll timer right now so
                            // the running preset starts honoring the new rate
                            // within one tick. No restart, no preset reload.
                            mappingEngine.applyPollRate()
                        }
                    }

                    // Live readout: shows what the engine is *actually*
                    // ticking at. If the user changes the picker, this
                    // line updates immediately because `currentPollHz`
                    // is @Published and applyPollRate() updates it.
                    if mappingEngine.isRunning {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Engine running at \(mappingEngine.currentPollHz) Hz")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Pause") {
                                mappingEngine.stop()
                            }
                            .buttonStyle(.solidSecondaryCompact)
                            .help("Stop the active preset. You can change the rate, then click Resume on the main screen to start again.")
                        }
                    } else if let last = mappingEngine.activePreset {
                        HStack(spacing: 6) {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Engine stopped. Rate will be \(pollHz) Hz on next start.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Resume") {
                                mappingEngine.start(with: last)
                            }
                            .buttonStyle(.solidCompact)
                            .help("Re-start the most recently active preset with the chosen rate.")
                        }
                    }

                    if !autoPollByPower && pollHz > 120 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Sacrifices battery life and CPU. Higher rates can also cause UI hitches in the binding editor while a preset is active. Drop back to 120 Hz if the app feels sluggish.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if !autoPollByPower && pollHz < 120 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Lower rate saves battery but may add noticeable latency on fast-twitch inputs like rapid-fire and gyro aim.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                section(title: "System Performance") {
                    SystemStatsPanel()
                }

                section(title: "Gaming Utilities (Global Defaults)") {
                    GamingUtilitiesPanel()
                }

                section(title: "Data & Storage") {
                    Text("Every preset, group, snapshot, statistic, calibration, and touchpad region is stored inside the app's sandbox container in Application Support and the Preferences plist. App Store updates only replace the app bundle; this container is left untouched, so nothing you've configured is lost on update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Reveal Data Folder") {
                            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            let dataDir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
                            NSWorkspace.shared.activateFileViewerSelecting([dataDir])
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        Button("Export Backup…") {
                            exportBackup()
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        Button("Restore from Backup…") {
                            importBackup()
                        }
                        .buttonStyle(.solidSecondaryCompact)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Section header + indented content. Replaces SwiftUI's `Form > Section`
    /// which produces a cramped two-column layout on macOS.
    @ViewBuilder
    /// Visually-grouped section card. Each section gets a bold header,
    /// inset content with consistent vertical rhythm, and a subtle
    /// rounded-rectangle background that delineates one section from
    /// the next. Improves readability of long tab contents (the user
    /// said the Controllers / About tabs were "not easy to see").
    private func section<Content: View>(title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Backup / Restore

    /// Bundle every piece of user state into one JSON envelope on the user's
    /// chosen filesystem location. Useful for migrating between Macs and for
    /// belt-and-suspenders backups even though the sandbox container
    /// already survives App Store updates.
    private func exportBackup() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "InputConfig-Backup-\(formatter.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let envelope = makeBackupEnvelope()
            if let data = try? JSONSerialization.data(withJSONObject: envelope,
                                                      options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Pick a backup envelope and restore every piece of state from it.
    /// Existing data is overwritten by snapshotting first into the version
    /// history so the user can undo via Revert.
    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url),
                  let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            restoreBackup(envelope)
        }
    }

    private func makeBackupEnvelope() -> [String: Any] {
        var presetsArray: [[String: Any]] = []
        for p in presetStore.presets {
            if let data = try? JSONEncoder().encode(p),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                presetsArray.append(dict)
            }
        }
        var groupsArray: [[String: Any]] = []
        for g in presetStore.groups {
            if let data = try? JSONEncoder().encode(g),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                groupsArray.append(dict)
            }
        }
        // Trash (soft-deleted presets). Captures both the preset and the
        // original deletedAt timestamp so a "restore on new Mac" landing
        // doesn't reset the trash's chronological ordering. Older
        // restores that lack this field just skip the trash block.
        var trashArray: [[String: Any]] = []
        for snap in presetStore.snapshotTrashForBackup() {
            if let data = try? JSONEncoder().encode(snap),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                trashArray.append(dict)
            }
        }
        // Mirror selected UserDefaults that we own.
        let defaults = UserDefaults.standard
        var prefs: [String: Any] = [:]
        // Every UserDefaults key the app owns. Adding new keys here is
        // how they get carried by Export Backup; missing entries silently
        // reset when the user restores on a new Mac. Grouped roughly
        // by subsystem for readability.
        let exportedKeys: [String] = [
            // Touchpad
            "InputConfig.touchpadCalibration.v1",
            "InputConfig.touchpadRegions.v1",
            "InputConfig.touchpadActiveDevice.v2",
            // Cursor / stick regions
            "InputConfig.cursorRegions.v1",
            "InputConfig.stickRegions.v1",
            // Cursor guard (gaming utilities)
            "CursorGuard.edgeConfine",
            "CursorGuard.edgeBufferPx",
            "CursorGuard.autoRecenter",
            "CursorGuard.recenterIntervalMs",
            "CursorGuard.hideWhileRunning",
            "CursorGuard.sensitivity",
            // Engine poll rate
            "InputConfig.pollHz",
            "InputConfig.autoPollHzByPower",
            "InputConfig.pollHzOnAC",
            "InputConfig.pollHzOnBattery",
            // UI
            "InputConfig.showMenuBarIcon",
            "InputConfig.debugLogExpanded",
            "VirtualController.scale",
            // External input
            "InputConfig.externalInput.excludeBuiltIn",
            // Update + session
            "InputConfig.updateCheck.enabled",
            "InputConfig.updateCheck.dismissedVersions",
            "InputConfig.sessionRestore.enabled",
            "InputConfig.freezeWatchdog.enabled",
            // Misc
            "InputConfig.tipCount",
            "InputConfig.seededExampleGroups.v1",
            "InputConfig.seededExamples.v1",
            "InputConfig.seededExampleNames.v1",
            "InputConfig.appliedDefaultGroupColors.v2",
        ]
        for key in exportedKeys {
            if let v = defaults.object(forKey: key) {
                // Encode Data values as base64 strings for JSON portability.
                if let d = v as? Data {
                    prefs[key] = d.base64EncodedString()
                } else {
                    prefs[key] = v
                }
            }
        }
        return [
            "schemaVersion": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "presets": presetsArray,
            "groups": groupsArray,
            "trash": trashArray,
            "userDefaults": prefs
        ]
    }

    private func restoreBackup(_ envelope: [String: Any]) {
        // Schema-version gate. v1 is the only published format right now.
        // Anything higher means the backup was written by a newer app
        // version; we refuse rather than partially-restore unknown keys.
        // Anything missing the field at all is treated as v1 for
        // backwards compatibility with the original beta backups.
        let version = (envelope["schemaVersion"] as? Int) ?? 1
        guard version <= 1 else {
            NSLog("SettingsView.restoreBackup: unsupported schema version \(version) - aborting restore")
            return
        }

        // Presets: match existing presets by UUID and skip any that already
        // exist locally, mirroring the Groups path below. Without this, a
        // restore silently overwrote a local preset and its edits whenever the
        // two shared a UUID (e.g. restoring onto a Mac that already has the
        // same preset). Skipping preserves the local copy.
        if let presetsArray = envelope["presets"] as? [[String: Any]] {
            let existingIDs = Set(presetStore.presets.map { $0.id })
            for dict in presetsArray {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   var preset = try? JSONDecoder().decode(Preset.self, from: data) {
                    if existingIDs.contains(preset.id) { continue }
                    // Force a safe, app-generated on-disk filename. The decoded
                    // filename comes from an untrusted backup file and could
                    // contain path components (e.g. "../../") that savePreset
                    // would otherwise resolve outside the presets directory.
                    preset.filename = Preset.generateFilename()
                    presetStore.savePreset(preset)
                }
            }
        }
        // Groups: match existing entries by UUID, not name. The old code
        // skipped a backup group when ANY existing group happened to
        // share its display name, which silently destroyed the user's
        // saved group color and merged unrelated presets together if
        // two users on different Macs both had a "Gaming" group. Going
        // through UUID lets us tell apart same-name-different-identity
        // and preserves the original group's color + name + ordering.
        if let groupsArray = envelope["groups"] as? [[String: Any]] {
            let existingIDs = Set(presetStore.groups.map { $0.id })
            for dict in groupsArray {
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let group = try? JSONDecoder().decode(PresetGroup.self, from: data) else {
                    continue
                }
                if existingIDs.contains(group.id) {
                    // Same group identity already exists locally; skip
                    // so we don't clobber the user's current name +
                    // color tint. (Future enhancement: surface a merge
                    // dialog rather than silently skipping.)
                    continue
                }
                presetStore.upsertGroup(group)
            }
        }
        // Trash: legacy backups don't have this section. Newer backups
        // include the recently-deleted preset list so a user restoring
        // on a new Mac sees the same trash bin they had on the original.
        if let trashArray = envelope["trash"] as? [[String: Any]] {
            for dict in trashArray {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let snap = try? JSONDecoder().decode(PresetStore.TrashSnapshot.self, from: data) {
                    // Untrusted backup: force a safe on-disk filename before it
                    // reaches the trash directory write (path-traversal guard).
                    var p = snap.preset
                    p.filename = Preset.generateFilename()
                    presetStore.restoreTrashFromBackup(preset: p, deletedAt: snap.deletedAt)
                }
            }
        }
        // UserDefaults. Every Data-typed key that export base64-encodes must
        // be base64-decoded here, or it is restored as a raw base64 string and
        // silently corrupted. Previously only "InputConfig.touchpad*" keys were
        // decoded, which dropped cursorRegions.v1 and stickRegions.v1.
        let dataKeys: Set<String> = [
            "InputConfig.touchpadCalibration.v1",
            "InputConfig.touchpadRegions.v1",
            "InputConfig.touchpadActiveDevice.v2",
            "InputConfig.cursorRegions.v1",
            "InputConfig.stickRegions.v1",
        ]
        if let prefs = envelope["userDefaults"] as? [String: Any] {
            let defaults = UserDefaults.standard
            for (key, value) in prefs {
                if dataKeys.contains(key), let str = value as? String, let data = Data(base64Encoded: str) {
                    defaults.set(data, forKey: key)
                } else {
                    defaults.set(value, forKey: key)
                }
            }
        }
    }

    // MARK: - Controllers

    private var controllersTab: some View {
        // Wrapped in a ScrollView with section helpers so the layout reads
        // top-down like the General tab. The previous version used
        // ContentUnavailableView which expanded to fill the whole sheet,
        // leaving a huge gap between the header and a floating empty state.
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Connected Controllers") {
                    HStack {
                        Spacer()
                        Button {
                            controllerService.refreshControllers()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.solidSecondaryCompact)
                    }
                    .padding(.bottom, -4)

                    if !hasAnyController {
                        // Compact empty state that sits flush under the
                        // header rather than centering itself in dead space.
                        emptyControllersCard
                    } else {
                        if !controllerService.connectedControllers.isEmpty {
                            controllersList
                        }
                        // Controllers macOS does not expose through the game
                        // controller framework (e.g. an 8BitDo in a non-MFi
                        // mode) are read over raw HID and were previously
                        // invisible here, which made it look like nothing was
                        // detected. List them too.
                        if !controllerService.rawHIDGamepadSlots.isEmpty {
                            rawHIDControllersList
                        }
                    }
                }

                if !hasAnyController {
                    section(title: "How to Connect") {
                        connectionTipsView
                    }
                }

                section(title: "Cursor Regions") {
                    Text("Draw zones on screen and bind them as Cursor Region inputs. Works with any pointer, including the built-in trackpad.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Open Cursor Regions Editor…") {
                            showingCursorRegions = true
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        Text("\(CursorRegionService.shared.allRegions().count) defined")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                section(title: "Stick Regions") {
                    Text("Bind diagonals and quadrants on a stick as one input, instead of combining two axis half-bindings. Each stick has its own set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Open Stick Regions Editor…") {
                            showingStickRegions = true
                        }
                        .buttonStyle(.solidSecondaryCompact)
                        let leftCount = StickRegionService.shared.regions(forStick: 0).count
                        let rightCount = StickRegionService.shared.regions(forStick: 1).count
                        Text("\(leftCount) left / \(rightCount) right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// True when any controller is present through any path: a GameController
    /// framework device, the Steam virtual slot, or a raw-HID gamepad. The
    /// "Connected Controllers" section and the "How to Connect" hint key off
    /// this so a raw-HID-only controller no longer reads as "none detected".
    private var hasAnyController: Bool {
        !controllerService.connectedControllers.isEmpty
            || !controllerService.rawHIDGamepadSlots.isEmpty
            || controllerService.steamControllerSlot != nil
    }

    /// Cards for controllers read directly over raw HID (anything macOS does
    /// not surface through the GameController framework, such as an 8BitDo in
    /// a non-MFi mode or a wired Xbox 360 pad). They map exactly like any
    /// other controller; this list just makes them visible in Settings.
    private var rawHIDControllersList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controllerService.rawHIDGamepadSlots.keys.sorted(), id: \.self) { slot in
                if let gamepad = controllerService.rawHIDGamepadSlots[slot] {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ControllerGlyph(height: 14)
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(gamepad.displayName)
                                    .font(.body)
                                Text("Slot #\(slot) · detected over raw HID")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Text("macOS does not expose this controller through its game controller framework, so InputConfig reads it directly over HID. It still works for mapping. If it does not respond inside a preset, try switching it to a mode macOS reads natively - see the Help menu for your model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// Quiet inline card replacing the old `ContentUnavailableView`. Keeps the
    /// "no controllers" message visible without claiming the entire sheet.
    private var emptyControllersCard: some View {
        HStack(spacing: 14) {
            ControllerGlyph(height: 22)
                .foregroundStyle(.secondary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("No controllers connected")
                    .font(.body)
                Text("Plug in a USB controller or pair one over Bluetooth. It will show up here automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    /// Practical connection hints shown only when nothing is plugged in.
    private var connectionTipsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            tipRow(icon: "cable.connector",
                   title: "USB",
                   body: "Plug the controller in with its USB cable. Wired DualSense, DualShock 4, Xbox, and 8BitDo show up immediately.")
            tipRow(icon: "wave.3.right",
                   title: "Bluetooth",
                   body: "Hold the controller's pair button until its light flashes, then add it from System Settings → Bluetooth.")
            tipRow(icon: "checkmark.seal",
                   title: "Supported",
                   body: "DualSense / DualSense Edge, DualShock 4, Xbox One / Series / Elite, Switch Pro, Joy-Cons, Stadia, 8BitDo, Steam Controller, and any MFi or HID gamepad.")
        }
    }

    @ViewBuilder
    private func tipRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var controllersList: some View {
                // Live press log across all controllers. Press the button
                // you want to map (PS, mute, paddle, FN, etc.) and the
                // exact name Apple's framework reports appears here. Lets
                // us extend `knownButtonMap` to match whatever Sony's
                // newest firmware names the button.
                if !pressLog.recent.isEmpty {
                    GroupBox("Live press log") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(pressLog.recent.prefix(10)) { entry in
                                HStack(spacing: 6) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundStyle(.green)
                                        .accessibilityHidden(true)
                                    Text(entry.name)
                                        .font(.caption.monospaced())
                                    Spacer()
                                    if let idx = entry.mappedIndex {
                                        Text("btn \(idx)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("unmapped")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, 8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(controllerService.connectedControllers.enumerated()), id: \.offset) { index, controller in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ControllerGlyph(height: 14)
                                    .foregroundStyle(.blue)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(controller.vendorName ?? "Unknown Controller")
                                        .font(.body)
                                    Text("Slot #\(index)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            // Diagnostic: every button the physical input
                            // profile exposes, plus the index InputConfig
                            // assigns to it. Press any of these on the
                            // controller and use the same index in a binding.
                            DisclosureGroup("All detected buttons") {
                                let buttonNames = Array(controller.physicalInputProfile.buttons.keys).sorted()
                                if buttonNames.isEmpty {
                                    Text("No physical buttons reported by this controller.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(buttonNames, id: \.self) { name in
                                            HStack(spacing: 6) {
                                                Text(name)
                                                    .font(.caption.monospaced())
                                                Spacer()
                                                Text(indexLabel(forButtonName: name, slot: index))
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            .font(.caption)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
    }

    /// Look up the binding index assigned to the named physical button.
    /// Used by the controller diagnostic so the user can match Edge paddles /
    /// FN buttons to the indices they should type into a binding row.
    private func indexLabel(forButtonName name: String, slot: Int) -> String {
        if let known = GameControllerService.publicKnownButtonMap[name] {
            return "btn \(known)"
        }
        return "btn ?"
    }

    // MARK: - About

    /// Marketing version from the bundle's Info.plist (CFBundleShortVersionString).
    /// Falls back to "?" if the plist entry is missing.
    private var bundleShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Build number from the bundle's Info.plist (CFBundleVersion).
    private var bundleBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 22) {
                // App identity card - icon, name, tagline, version.
                VStack(spacing: 12) {
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 96, height: 96)
                    }
                    Text("InputConfig")
                        .font(.largeTitle.weight(.semibold))
                    Text("Universal Input Mapping for macOS")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Version \(bundleShortVersion) · Build \(bundleBuildNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("An accessible way to control your Mac, mapping controllers, keyboards, and mice to keyboard, mouse, MIDI, and more, anywhere on macOS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
                )

                // Creator + links.
                VStack(spacing: 6) {
                    Text("Created by Ryleigh Newman")
                        .font(.body.weight(.medium))
                    HStack(spacing: 12) {
                        Link(destination: URL(string: "https://ryleighnewman.com")!) {
                            Label("ryleighnewman.com", systemImage: "link")
                                .font(.callout)
                        }
                        Link(destination: URL(string: "https://github.com/ryleighnewman/InputConfig")!) {
                            Label("Open Source", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.callout)
                        }
                    }
                    Text("Contact me if you ever need anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
                )

                // Tip jar. Promotional CTA, not a form control, so it takes the
                // hero glass treatment rather than a bordered form button.
                Button {
                    TipJarWindowController.shared.show()
                } label: {
                    Label("Support Development", systemImage: "heart.fill")
                        .frame(minWidth: 200)
                }
                .buttonStyle(GlassCTAButton(tint: .pink))

                // Footer copyright.
                Text("Copyright \u{00A9} 2026 Ryleigh Newman. All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(20)
        }
    }
}

/// Self-contained toggle for the Launch at Login setting. Pulled out so
/// the Settings tab doesn't need to track the LoginItemService directly.
struct LaunchAtLoginToggleView: View {
    @StateObject private var service = LoginItemService.shared

    var body: some View {
        // Use a single-line Toggle. macOS Form right-aligns the toggle and
        // left-aligns its label cleanly when the label is a plain Text.
        // Description text goes underneath as a separate Form row so it
        // takes the full width and does not get truncated by the column.
        Toggle("Launch at Login", isOn: launchAtLoginBinding)
            .toggleStyle(.switch)
        Text("Open InputConfig automatically when you log in to macOS.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let err = service.lastError {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var launchAtLoginBinding: SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { service.isEnabled },
            set: { _ = service.setEnabled($0) }
        )
    }
}
#endif
