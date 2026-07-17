import SwiftUI
import GameController

/// Notifications used by the macOS menu bar (Controller and View menus)
/// to drive UI actions on the active ContentView. Posted from
/// InputConfigMain's `.commands`; handled by `onReceive` blocks in
/// ContentView below.
extension Notification.Name {
    static let inputConfigShowStats              = Notification.Name("InputConfig.ShowStats")
    static let inputConfigOpenSmartMaker         = Notification.Name("InputConfig.OpenSmartMaker")
    static let inputConfigToggleActivePreset     = Notification.Name("InputConfig.ToggleActive")
    static let inputConfigOpenTouchpadCalibration = Notification.Name("InputConfig.OpenTouchpadCal")
    static let inputConfigOpenMotionCalibration   = Notification.Name("InputConfig.OpenMotionCal")
    static let inputConfigStartTutorial          = Notification.Name("InputConfig.StartTutorial")
    static let inputConfigScrollToPreset         = Notification.Name("InputConfig.ScrollToPreset")
    /// Fired by the Quick Tour when it needs the PresetDetailView's
    /// internal ScrollView to scroll down to the Live Visualizer
    /// section. The detail view listens and expands the disclosure
    /// before scrolling.
    static let inputConfigScrollToVisualizer     = Notification.Name("InputConfig.ScrollToVisualizer")
    /// Tour scrolls the preset-detail back up to the top (header /
    /// Activate button area).
    static let inputConfigScrollToTop            = Notification.Name("InputConfig.ScrollToTop")
    /// Tour scrolls the preset editor's binding list to its
    /// Automation panel at the bottom.
    static let inputConfigScrollToAutomation     = Notification.Name("InputConfig.ScrollToAutomation")
    /// Tour scrolls the editor's binding list back to the top so the
    /// first binding row + its Options disclosure are visible.
    static let inputConfigScrollToFirstBinding   = Notification.Name("InputConfig.ScrollToFirstBinding")
    /// Tour fires this with a binding UUID; the matching
    /// BindingRowView flips its showAdvanced flag so the user sees
    /// the Options disclosure expand on its own.
    static let inputConfigExpandBindingOptions   = Notification.Name("InputConfig.ExpandBindingOptions")
}

struct ContentView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine
    @EnvironmentObject var eightBitDoDetector: EightBitDoDetector
    @ObservedObject private var accessibility = AccessibilityPermissionService.shared

    @State private var selectedPresetId: UUID?
    @State private var showAccessibilityAlert = false
    /// Proactive, reassuring Accessibility explainer shown on launch when the
    /// permission isn't granted yet, so people aren't left with non-working
    /// mappings just because macOS never surfaced its own prompt.
    @State private var showingAccessibilityIntro = false
    /// User opt-out for the launch explainer above. The persistent banner and
    /// the on-activation alert still cover them if they later need it.
    @AppStorage("suppressAccessibilityIntro") private var suppressAccessibilityIntro = false
    /// Shows the developer activity log pinned under the detail pane. Off by
    /// default so the shipping UI is clean; toggled from Settings → Advanced.
    @AppStorage("InputConfig.showDebugLog") private var showDebugLog = false
    @State private var showingSmartMaker = false
    @State private var editingPreset: Preset?
    @State private var newlyCreatedPresetId: UUID?
    @State private var showingImportSheet = false
    @State private var presentedDemoKind: FeatureDemoKind?
    @State private var showingStats: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingTouchpadCalibrationFromMenu: Bool = false
    @State private var showingMotionCalibrationFromMenu: Bool = false
    /// Carries a preset waiting for the user to acknowledge a calibration
    /// prompt before its mapping engine starts.
    @State private var pendingActivation: (preset: Preset, reqs: CalibrationRequirements)?
    /// Tracks whether the mapping engine was running when the user opened the
    /// preset editor, so we can flag that in the editor's banner and decide
    /// whether to offer to re-activate on close.
    @State private var engineWasRunningBeforeEdit: Bool = false
    /// When the user clicks an input on the Live Visualizer, we stash the
    /// jump target here. The PresetEditorView sheet reads this on appear and
    /// scrolls + pulses the matching binding row.
    @State private var pendingEditorJump: EditorJumpTarget?
    /// Preset queued for confirm-delete. Drives the .confirmationDialog so
    /// users can't permanently wipe a preset with a single misclick.
    @State private var presetPendingDelete: Preset?
    /// Shown when the Trash disclosure in the sidebar is expanded.
    @State private var showingTrashDisclosure: Bool = false
    /// Briefly set to a preset UUID when we want the sidebar row to
    /// flash. Cleared after the animation completes.
    @State private var flashingPresetID: UUID?
    /// Live map of tutorial-anchor ids to their global frames. Refreshed
    /// by .onPreferenceChange so the spotlight overlay tracks UI moves.
    @State private var tutorialAnchors: [String: CGRect] = [:]
    /// Shared tutorial controller - drives both the spotlight overlay
    /// (here in the main window) and the floating tutorial card panel.
    @StateObject private var tutorialState = TutorialState.shared
    /// Index of the welcome-page feature card currently being showcased
    /// by the tutorial. Drives a pulsing highlight + auto-opens its demo
    /// sheet during the "example presets" tutorial step.
    @State private var tutorialFeatureSpotlight: FeatureDemoKind?

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        // Kill the blue keyboard-focus ring that macOS draws around toolbar
        // buttons (including the system sidebar toggle and our Home button)
        // when they retain focus after a click.
        .focusEffectDisabled()
        .toolbar {
            // Sits immediately to the right of the traffic-light buttons on
            // macOS, which is what the user wanted ("next to the window
            // closer button"). Returns to the welcome screen.
            ToolbarItem(placement: .navigation) {
                Button {
                    selectedPresetId = nil
                } label: {
                    Label("Home", systemImage: "house.fill")
                }
                .help("Return to the welcome screen")
                .spotlightAnchor(SpotlightID.homeButton)
                .accessibilityLabel("Home")
                .accessibilityHint("Returns to the welcome screen")
            }
            // Stats button sits next to Home (leading edge) so it never
            // pushes content like Activate / Edit toward the right side
            // of the title bar, and it can't visually collide with the
            // window edge.
            ToolbarItem(placement: .navigation) {
                Button {
                    showingStats = true
                } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .symbolRenderingMode(.hierarchical)
                }
                .help("Show statistics")
                .spotlightAnchor(SpotlightID.statsButton)
                .accessibilityLabel("Statistics")
                .accessibilityHint("Opens the lifetime statistics dashboard")
            }

            // Trailing - settings shortcut only. Active-preset chip and
            // controller status pill were removed at the user's request -
            // active state lives elsewhere (sidebar status, preset row
            // green dot) and the toolbar reads cleaner without them.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettingsSheet = true
                } label: {
                    Image(systemName: "gear")
                        .symbolRenderingMode(.hierarchical)
                }
                .help("Settings")
                .spotlightAnchor(SpotlightID.settingsButton)
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens app settings")
            }
        }
        .safeAreaInset(edge: .top) { accessibilityBanner }
        // Hierarchical rendering across the whole app: every colored SF Symbol
        // draws its tint at varying opacities (transparency in the secondary
        // layers) instead of one flat solid fill. Set once at the root; the
        // environment value propagates into every sheet and popover too.
        .symbolRenderingMode(.hierarchical)
        .alert("Accessibility access needed", isPresented: $showAccessibilityAlert) {
            Button("Open Accessibility Settings") { accessibility.openSystemSettings() }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("To send the keyboard and mouse actions in this preset, turn on InputConfig under System Settings → Privacy & Security → Accessibility. Your mappings will start working as soon as you do.")
        }
        .sheet(isPresented: $showingStats) {
            StatsView()
                .glassBackground()
        }
        .sheet(isPresented: $showingSmartMaker) {
            SmartPresetMakerView { preset in
                selectedPresetId = preset.id
                flashingPresetID = preset.id
                NotificationCenter.default.post(name: .inputConfigScrollToPreset, object: preset.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if flashingPresetID == preset.id {
                        withAnimation(.easeOut(duration: 0.9)) { flashingPresetID = nil }
                    }
                }
            }
            .environmentObject(presetStore)
            .environmentObject(controllerService)
            .glassBackground()
        }
        .sheet(isPresented: $showingSettingsSheet) {
            // Done lives in a translucent footer inside the sheet rather than
            // the system confirmation bar, which draws its own opaque
            // background and broke the frosted look at the bottom of Settings.
            VStack(spacing: 0) {
                SettingsView()
                    .environmentObject(presetStore)
                    .environmentObject(controllerService)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showingSettingsSheet = false }
                        .buttonStyle(.solid)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(minWidth: 620, minHeight: 480)
            .glassBackground()
        }
        .sheet(isPresented: $showingTouchpadCalibrationFromMenu) {
            TouchpadCalibrationView()
                .environmentObject(presetStore)
                .glassBackground()
        }
        .sheet(isPresented: $showingMotionCalibrationFromMenu) {
            MotionCalibrationView()
                .environmentObject(controllerService)
                .glassBackground()
        }
        .alert(
            "Calibration recommended",
            isPresented: Binding(
                get: { pendingActivation != nil },
                set: { newValue in
                    if newValue == false { pendingActivation = nil }
                }
            ),
            presenting: pendingActivation
        ) { pending in
            // Always offer to activate anyway as a way out.
            if pending.reqs.needsMotion {
                Button("Calibrate Motion…") {
                    let toResume = pending.preset
                    pendingActivation = nil
                    showingMotionCalibrationFromMenu = true
                    // Note: we don't auto-resume activation after the user
                    // closes the calibration sheet - they probably want to
                    // check the result first. They can re-activate when
                    // they're ready.
                    _ = toResume
                }
            }
            if pending.reqs.needsTouchpad {
                Button("Calibrate Touchpad…") {
                    pendingActivation = nil
                    showingTouchpadCalibrationFromMenu = true
                }
            }
            Button("Activate Anyway") {
                let toStart = pending.preset
                pendingActivation = nil
                startEngine(with: toStart)
            }
            Button("Cancel", role: .cancel) {
                pendingActivation = nil
            }
        } message: { pending in
            if pending.reqs.needsMotion && pending.reqs.needsTouchpad {
                Text("This preset uses both motion and touchpad inputs. Calibrate them first so the cursor and aim feel right on your controller - InputConfig doesn't yet know your controller's resting drift or your touchpad's usable bounds.")
            } else if pending.reqs.needsMotion {
                Text("This preset binds gyroscope or accelerometer inputs and the connected motion-capable controller hasn't been calibrated yet. Calibrating sets the resting zero so a still controller doesn't move the cursor.")
            } else if pending.reqs.needsTouchpad {
                Text("This preset binds touchpad inputs and your touchpad bounds haven't been calibrated yet. Calibrating helps swipes feel uniform across the surface.")
            }
        }
        .confirmationDialog(
            "Delete preset?",
            isPresented: Binding(
                get: { presetPendingDelete != nil },
                set: { if !$0 { presetPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: presetPendingDelete
        ) { preset in
            Button("Delete \"\(preset.name)\"", role: .destructive) {
                performPendingDelete()
            }
            Button("Cancel", role: .cancel) {
                presetPendingDelete = nil
            }
        } message: { preset in
            Text("\"\(preset.name)\" will be moved to the Trash at the bottom of the sidebar. Restore it from there any time.")
        }
        .modifier(TutorialPlumbing(
            state: tutorialState,
            anchors: $tutorialAnchors,
            onTutorialEnded: handleTutorialEnded
        ))
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigShowStats)) { _ in
            showingStats = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigOpenSmartMaker)) { _ in
            showingSmartMaker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigToggleActivePreset)) { _ in
            // Toggle the sidebar-selected preset, if any.
            if let pid = selectedPresetId,
               let preset = presetStore.presets.first(where: { $0.id == pid }) {
                togglePreset(preset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigOpenTouchpadCalibration)) { _ in
            showingTouchpadCalibrationFromMenu = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigOpenMotionCalibration)) { _ in
            showingMotionCalibrationFromMenu = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigStartTutorial)) { _ in
            startTutorial()
        }
        .onChange(of: tutorialState.isActive) { _, active in
            // When the tutorial ends (Finish, Skip, or natural end),
            // restore the controller list so the synthetic Edge entry
            // disappears alongside the tutorial.
            if !active && controllerService.tutorialFakeControllerActive {
                controllerService.disableTutorialFakeController()
            }
        }
        .onChange(of: editingPreset?.id) { _, newID in
            // Pause outputs (but keep the engine polling) so an active
            // preset's bindings don't fling the cursor / fire keystrokes /
            // send MIDI while the user is configuring or calibrating. The
            // engine keeps reading inputs so the green row highlight on each
            // binding still lights up when the user presses the controller.
            if newID != nil {
                engineWasRunningBeforeEdit = mappingEngine.isRunning
                mappingEngine.outputsPaused = true
            } else {
                mappingEngine.outputsPaused = false
            }
        }
        .sheet(item: $editingPreset, onDismiss: handleEditorDismiss) { preset in
            PresetEditorView(preset: preset,
                             enginePausedNotice: engineWasRunningBeforeEdit,
                             pendingJump: pendingEditorJump) { updated in
                newlyCreatedPresetId = nil // Saved successfully, don't delete
                presetStore.savePreset(updated)
                // If the edited preset is the one currently running, restart the
                // engine with the new value so it rebuilds its binding caches;
                // otherwise edits would not take effect until the next activation.
                if mappingEngine.isRunning && presetStore.activePresetId == updated.id {
                    mappingEngine.start(with: updated)
                }
                editingPreset = nil
            }
            .environmentObject(controllerService)
            .environmentObject(mappingEngine)
            .environmentObject(presetStore)
            .frame(minWidth: 1150, idealWidth: 1300, minHeight: 700, idealHeight: 800)
            .glassBackground()
        }
        .onAppear {
            presetStore.reseedExamplePresets()
            // Proactively explain + offer Accessibility on launch if it isn't
            // granted, since macOS doesn't always surface its own prompt and
            // the app's mappings can't fire without it.
            accessibility.refresh()
            if !accessibility.isTrusted && !suppressAccessibilityIntro {
                showingAccessibilityIntro = true
            }
        }
        .sheet(isPresented: $showingAccessibilityIntro) {
            accessibilityIntroSheet
                .glassBackground()
        }
        .sheet(item: $presentedDemoKind) { kind in
            FeatureDemoView(
                kind: kind,
                onJumpToPreset: { presetName in
                    presentedDemoKind = nil
                    jumpToPreset(named: presetName)
                },
                onOpenStatistics: {
                    // Dismiss this sheet first, then present the stats sheet.
                    // Two sheets can't be presented from the same view at once.
                    presentedDemoKind = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingStats = true }
                },
                onOpenSettings: {
                    presentedDemoKind = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingSettingsSheet = true }
                }
            )
            .glassBackground()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: GlobalHotKeyService.toggleNotification)) { _ in
            handleGlobalHotkeyToggle()
        }
        .modifier(DebugAutomationHooks(
            presetStore: presetStore,
            selectedPresetId: $selectedPresetId,
            editingPreset: $editingPreset,
            showingSmartMaker: $showingSmartMaker,
            showingStats: $showingStats,
            showingSettingsSheet: $showingSettingsSheet,
            showingMotion: $showingMotionCalibrationFromMenu,
            showingTouchpad: $showingTouchpadCalibrationFromMenu,
            presentedDemoKind: $presentedDemoKind,
            onToggle: { togglePreset($0) }
        ))
        .debugFakeController(controllerService)
        .debugCaptureSheets()
    }

    /// Fired by the global keyboard shortcut. If a preset is currently active,
    /// stop it; otherwise re-activate the most recently used preset (falling
    /// back to the first preset). Goes through the same togglePreset path so
    /// calibration gates and the Accessibility prompt still apply.
    private func handleGlobalHotkeyToggle() {
        if let active = presetStore.presets.first(where: { $0.isActive }) {
            togglePreset(active)
            return
        }
        let target = presetStore.lastActivatedPresetId
            .flatMap { id in presetStore.presets.first(where: { $0.id == id }) }
            ?? presetStore.presets.first
        if let target { togglePreset(target) }
    }

    /// Select a preset by name, scroll it into view, and briefly flash it
    /// green so the user sees where it landed. Shared by the feature-demo
    /// "Take me to an example" button and the per-controller example jump.
    private func jumpToPreset(named presetName: String) {
        guard let preset = presetStore.presets.first(where: { $0.name == presetName }) else { return }
        selectedPresetId = preset.id
        flashingPresetID = preset.id
        NotificationCenter.default.post(
            name: .inputConfigScrollToPreset,
            object: preset.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if flashingPresetID == preset.id {
                withAnimation(.easeOut(duration: 0.9)) { flashingPresetID = nil }
            }
        }
    }

    // MARK: - Sidebar

    @State private var creatingGroupForPreset: Preset?
    @State private var newGroupName: String = ""
    @State private var renamingGroup: PresetGroup?
    @State private var renameGroupName: String = ""
    @FocusState private var groupNameFocused: Bool
    /// The group whose color popover is open (nil = none). Drives a per-row
    /// popover with tinted swatches + the macOS color picker.
    @State private var colorEditingGroup: PresetGroup?
    /// Working color for the folder color picker's "Custom" well.
    @State private var folderPickerColor: Color = .accentColor
    /// The most recently created group ID. Drives a brief green-flash
    /// animation in the sidebar so the user's eye lands on the new entry.
    @State private var flashingGroupID: UUID?

    private var sidebarView: some View {
        VStack(spacing: 0) {
            controllerStatusBar

            ScrollViewReader { proxy in
            List(selection: $selectedPresetId) {
                // Render each user-defined group as a collapsible section.
                // .onMove makes the group order drag-rearrangeable; the
                // green-flash animation is driven by `flashingGroupID`.
                ForEach(presetStore.topLevelGroups) { group in
                    groupSection(group, depth: 0)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(group.id == flashingGroupID
                                      ? Color.green.opacity(0.35)
                                      : Color.clear)
                                .animation(.easeOut(duration: 0.9),
                                           value: flashingGroupID)
                        )
                        // Pull the row's leading edge left so List's default
                        // sidebar indent doesn't leave a fat empty gap to the
                        // left of the disclosure chevron. With this inset the
                        // chevron sits visually centered between the sidebar's
                        // left edge and the start of the colored folder chip.
                        .listRowInsets(EdgeInsets(top: 2, leading: -6,
                                                  bottom: 2, trailing: 6))
                }
                .onMove { source, destination in
                    withAnimation(.spring(response: 0.35)) {
                        presetStore.moveTopLevelGroups(fromOffsets: source, toOffset: destination)
                    }
                }

                // Default "Ungrouped" section if there are any ungrouped presets.
                let ungrouped = presetStore.presets(in: nil)
                if !ungrouped.isEmpty {
                    Section {
                        ForEach(ungrouped) { preset in
                            presetRow(for: preset, leadingInset: 8)
                        }
                    } header: {
                        Text(presetStore.groups.isEmpty ? "Presets" : "Ungrouped")
                            .font(.caption)
                    }
                }

                // Trash - shown only when there's something in it. Each
                // entry has Restore + Permanently Delete actions. No TTL -
                // entries persist on disk until the user acts on them.
                if !presetStore.recentlyDeleted.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showingTrashDisclosure) {
                            ForEach(presetStore.recentlyDeleted) { entry in
                                trashRow(entry: entry)
                            }
                            Button {
                                presetStore.emptyTrash()
                            } label: {
                                Label("Empty Trash", systemImage: "trash.slash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.solidSecondaryCompact)
                            .padding(.top, 4)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.orange)
                                Text("Trash (\(presetStore.recentlyDeleted.count))")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onReceive(NotificationCenter.default.publisher(for: .inputConfigScrollToPreset)) { note in
                guard let id = note.object as? UUID else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inputConfigImportedPreset)) { note in
                // Newly imported preset hint: select, scroll, flash.
                // The flash uses the same flashingPresetID state the
                // FeatureDemo "jump to preset" flow already uses, so
                // the visual treatment matches across the app.
                guard let id = note.object as? UUID else { return }
                selectedPresetId = id
                flashingPresetID = id
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if flashingPresetID == id {
                        withAnimation(.easeOut(duration: 0.9)) { flashingPresetID = nil }
                    }
                }
            }
            } // ScrollViewReader

            bottomToolbar
        }
        .navigationTitle("Presets")
        .frame(minWidth: 280)
        .spotlightAnchor(SpotlightID.sidebar)
        .sheet(item: $creatingGroupForPreset) { preset in
            newGroupSheet(for: preset)
                .glassBackground()
        }
        .sheet(item: $renamingGroup) { group in
            renameGroupSheet(for: group)
                .glassBackground()
        }
    }

    /// Render a folder and everything under it. Recursive: a folder's content
    /// is its child folders (each rendered by another `groupSection` call) and
    /// then its own presets, so folders can nest to any depth. Returns AnyView
    /// because an opaque `some View` can't reference itself recursively.
    private func groupSection(_ group: PresetGroup, depth: Int = 0) -> AnyView {
        let presetsInGroup = presetStore.presets(in: group.id)
        let childGroups = presetStore.subgroups(of: group.id)
        return AnyView(
            DisclosureGroup(isExpanded: groupExpandedBinding(for: group)) {
                // Nested folders first, then this folder's own presets.
                ForEach(childGroups) { sub in
                    groupSection(sub, depth: depth + 1)
                }
                ForEach(presetsInGroup) { preset in
                    presetRow(for: preset)
                }
                if childGroups.isEmpty && presetsInGroup.isEmpty {
                    Text("Drop a preset here, or add a subfolder.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                }
            } label: {
                let tint = groupTintColor(for: group)
                HStack(spacing: 6) {
                    Image(systemName: tint == nil ? "folder" : "folder.fill")
                        .font(.caption)
                        // Liquid-glass folder chips: a vertical gradient of the
                        // folder's own color (bright where light would catch the
                        // top edge, deeper toward the base) rendered genuinely
                        // see-through, so the frosted sidebar reads through the
                        // icon instead of it sitting as a flat paint chip.
                        .foregroundStyle(
                            tint.map { c in
                                AnyShapeStyle(LinearGradient(
                                    colors: [c.opacity(0.95), c.opacity(0.45)],
                                    startPoint: .top, endPoint: .bottom))
                            } ?? AnyShapeStyle(.secondary)
                        )
                        .opacity(tint == nil ? 1 : 0.75)
                    Text(group.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                // Keep the folder icon tight to the disclosure arrow. Nesting
                // depth is already conveyed by the List's own per-level indent,
                // so no extra manual left-indent is added here.
                .padding(.leading, 2)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Rename Folder...") {
                        renameGroupName = group.name
                        renamingGroup = group
                    }
                    Button("Folder Color...") {
                        colorEditingGroup = group
                    }
                    Button("New Subfolder...") {
                        let id = presetStore.createGroup(named: "New Folder", parentID: group.id)
                        presetStore.setGroupExpanded(group.id, true)
                        if let g = presetStore.groups.first(where: { $0.id == id }) {
                            renameGroupName = g.name
                            renamingGroup = g
                        }
                    }
                    Menu("Move to Folder") {
                        Button("Top Level (no parent)") {
                            presetStore.setGroupParent(group.id, parentID: nil)
                        }
                        let targets = eligibleParentFolders(for: group)
                        if !targets.isEmpty {
                            Divider()
                            ForEach(targets) { target in
                                Button(target.name) {
                                    presetStore.setGroupParent(group.id, parentID: target.id)
                                    presetStore.setGroupExpanded(target.id, true)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete Folder", role: .destructive) {
                        presetStore.deleteGroup(group.id)
                    }
                }
                .popover(isPresented: Binding(
                    get: { colorEditingGroup?.id == group.id },
                    set: { if !$0 { colorEditingGroup = nil } }
                ), arrowEdge: .trailing) {
                    folderColorPopover(for: group)
                }
            }
            // Allow dropping presets onto this folder header to add them.
            .dropDestination(for: String.self) { items, _ in
                for item in items {
                    if let uuid = UUID(uuidString: item) {
                        presetStore.setPresetGroup(uuid, groupID: group.id)
                    }
                }
                return true
            }
        )
    }

    /// Folders this folder may be moved into: every folder except itself and
    /// its own descendants (moving into those would create a cycle).
    private func eligibleParentFolders(for group: PresetGroup) -> [PresetGroup] {
        presetStore.groups
            .filter { !presetStore.isGroup($0.id, descendantOfOrEqualTo: group.id) }
            .sorted { $0.name < $1.name }
    }

    /// Map a `PresetGroup.color` value to a SwiftUI Color, or nil for no
    /// tint. Accepts both a named palette color and a "#RRGGBB" hex string
    /// (chosen via the macOS color picker). Kept in the view layer so the
    /// model stays AppKit / Color agnostic.
    private func groupTintColor(for group: PresetGroup) -> Color? {
        guard let value = group.color else { return nil }
        if value.hasPrefix("#") { return Self.color(fromHex: value) }
        return namedColor(value)
    }

    /// Palette name -> Color (the fixed `PresetGroup.colorOptions` set).
    private func namedColor(_ name: String) -> Color? {
        switch name {
        case "blue":   return .blue
        case "purple": return .purple
        case "pink":   return .pink
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green":  return .green
        case "teal":   return .teal
        case "indigo": return .indigo
        case "brown":  return .brown
        default:       return nil
        }
    }

    /// Parse "#RRGGBB" into an sRGB Color. nil on malformed input.
    static func color(fromHex hex: String) -> Color? {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255.0,
                     green: Double((v >> 8) & 0xFF) / 255.0,
                     blue: Double(v & 0xFF) / 255.0)
    }

    /// Serialize a Color to "#RRGGBB" (sRGB) for storage in PresetGroup.color.
    static func hexString(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = max(0, min(255, Int(round(ns.redComponent * 255))))
        let g = max(0, min(255, Int(round(ns.greenComponent * 255))))
        let b = max(0, min(255, Int(round(ns.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Folder-color editor popover: tinted palette swatches (so the colors
    /// are actually visible) plus a macOS ColorPicker for any custom color
    /// (stored as hex). Also offers None / Restore Default.
    @ViewBuilder
    private func folderColorPopover(for group: PresetGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folder Color")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                ForEach(PresetGroup.colorOptions, id: \.self) { name in
                    Button {
                        presetStore.setGroupColor(group.id, color: name)
                        colorEditingGroup = nil
                    } label: {
                        Circle()
                            .fill(namedColor(name) ?? .gray)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().strokeBorder(
                                    Color.primary.opacity(group.color == name ? 0.9 : 0.15),
                                    lineWidth: group.color == name ? 2 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name.capitalized)
                    .accessibilityLabel(name.capitalized)
                    .accessibilityAddTraits(group.color == name ? [.isSelected] : [])
                }
            }

            Divider()

            // Any custom color via the native macOS color picker.
            HStack(spacing: 10) {
                ColorPicker("", selection: $folderPickerColor, supportsOpacity: false)
                    .labelsHidden()
                Text("Custom color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") {
                    presetStore.setGroupColor(group.id, color: Self.hexString(from: folderPickerColor))
                    colorEditingGroup = nil
                }
                .buttonStyle(.solidCompact)
            }

            Divider()

            HStack {
                Button("None") {
                    presetStore.setGroupColor(group.id, color: nil)
                    colorEditingGroup = nil
                }
                .buttonStyle(.solidSecondaryCompact)
                if ExamplePresets.groupDefaultColors[group.name] != nil {
                    Button("Restore Default") {
                        presetStore.applyDefaultGroupColor(group.id)
                        colorEditingGroup = nil
                    }
                    .buttonStyle(.solidSecondaryCompact)
                }
                Spacer()
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 250)
        .onAppear {
            folderPickerColor = groupTintColor(for: group) ?? .accentColor
        }
    }

    /// Sidebar row for one deleted preset. Restore moves it back to the
    /// presets directory; the trash icon permanently nukes the entry.
    @ViewBuilder
    private func trashRow(entry: PresetStore.DeletedPreset) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.preset.name)
                    .font(.caption)
                    .lineLimit(1)
                Text(trashDateString(entry.deletedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                _ = presetStore.restoreDeleted(entry)
                selectedPresetId = entry.preset.id
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Restore preset")
            .accessibilityLabel("Restore preset")
            Button {
                presetStore.permanentlyDelete(entry)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Permanently delete")
            .accessibilityLabel("Permanently delete preset")
        }
        .padding(.vertical, 2)
    }

    private func trashDateString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Deleted " + formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func presetRow(for preset: Preset, leadingInset: CGFloat = -18) -> some View {
        PresetRowView(
            preset: preset,
            onActivate: { togglePreset(preset) },
            onEdit: { editingPreset = preset },
            onDuplicate: { _ = presetStore.duplicatePreset(preset) },
            onExport: { exportPreset(preset) },
            onShowInFinder: { showPresetInFinder(preset) },
            onShare: { sharePreset(preset) },
            onImport: { showingImportSheet = true },
            onDelete: { confirmDelete(preset) },
            onConvert: { source, dest in
                _ = presetStore.convertPreset(preset, from: source, to: dest)
            }
        )
        .tag(preset.id)
        .id(preset.id) // For ScrollViewReader.scrollTo
        // List(.sidebar) default row insets give the row a fat
        // leading gutter (~16pt) which pushes the active-indicator
        // dot well away from the left edge. The DisclosureGroup
        // wrapping the group additionally indents children by the
        // disclosure-triangle width. Push hard with a generous
        // negative leading inset so the active dot sits flush with
        // the group disclosure column, and zero out the trailing
        // inset so the ellipsis sits flush with the right edge of
        // the sidebar.
        .listRowInsets(EdgeInsets(top: 2, leading: leadingInset,
                                  bottom: 2, trailing: 2))
        .listRowBackground(
            // Brief flash when the user jumps here from a feature demo;
            // otherwise a steady green hint marks the actively running
            // preset. Matches the system selection pill exactly: same
            // continuous-corner curvature and the same inset, so the green
            // hint sits in the identical box the blue selection draws.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(flashingPresetID == preset.id
                      ? Color.green.opacity(0.35)
                      : (preset.isActive ? Color.green.opacity(0.16) : Color.clear))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                // Deliberately NO implicit .animation here: List reuses row
                // views while scrolling, and an animation keyed on isActive /
                // flashingPresetID replayed the green fade on whichever preset
                // was recycled into the old active row's slot (a green flash
                // ~2/3 down the list while scrolling). The flash fade-out is
                // driven explicitly with withAnimation where the flash clears.
        )
        .draggable(preset.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            // Drop one preset onto another → create new group with both
            for item in items {
                if let uuid = UUID(uuidString: item), uuid != preset.id {
                    creatingGroupForPreset = preset
                    newGroupName = "New Group"
                    // Stash the dragged preset id by piggybacking on the
                    // existing creatingGroupForPreset state - we'll use both
                    // ids when the sheet's Create button is tapped.
                    pendingGroupPresetIDs = [preset.id, uuid]
                }
            }
            return true
        }
        .contextMenu {
            Menu("Move to Group") {
                ForEach(presetStore.groups) { group in
                    Button(group.name) {
                        presetStore.setPresetGroup(preset.id, groupID: group.id)
                    }
                }
                if !presetStore.groups.isEmpty {
                    Divider()
                }
                Button("New Group...") {
                    creatingGroupForPreset = preset
                    newGroupName = "New Group"
                    pendingGroupPresetIDs = [preset.id]
                }
                if preset.groupID != nil {
                    Divider()
                    Button("Remove from Group") {
                        presetStore.setPresetGroup(preset.id, groupID: nil)
                    }
                }
            }
        }
    }

    @State private var pendingGroupPresetIDs: [UUID] = []

    @ViewBuilder
    private func newGroupSheet(for preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group")
                .font(.headline)
            Text("Create a group to organize related presets together in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Group name", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    creatingGroupForPreset = nil
                    pendingGroupPresetIDs = []
                }
                .buttonStyle(.solidSecondary)
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = name.isEmpty ? "New Group" : name
                    let newID = presetStore.createGroup(named: resolved,
                                                        includingPresets: pendingGroupPresetIDs)
                    creatingGroupForPreset = nil
                    pendingGroupPresetIDs = []
                    // Brief green flash on the new group in the sidebar.
                    flashingGroupID = newID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                        if flashingGroupID == newID { flashingGroupID = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private func renameGroupSheet(for group: PresetGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Group")
                .font(.headline)
            TextField("Group name", text: $renameGroupName)
                .textFieldStyle(.roundedBorder)
                .focused($groupNameFocused)
            HStack {
                Spacer()
                Button("Cancel") {
                    renamingGroup = nil
                }
                .buttonStyle(.solidSecondary)
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = renameGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        presetStore.renameGroup(group.id, to: name)
                    }
                    renamingGroup = nil
                }
                .buttonStyle(.solid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            // Async so the sheet's field is in the window before focusing.
            DispatchQueue.main.async { groupNameFocused = true }
        }
    }

    private func groupExpandedBinding(for group: PresetGroup) -> SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { group.isExpanded },
            set: { _ in presetStore.toggleGroupExpanded(group.id) }
        )
    }

    private static let controllerColors: [Color] = [.green, .purple, .red, .orange, .cyan, .pink, .yellow, .mint]

    /// An 8BitDo controller is considered to be in the wrong mode if HID
    /// detection sees it but the GameController framework does not have a
    /// corresponding entry (or has fewer entries than the HID detector).
    private var eightBitDoModeWarning: EightBitDoDevice? {
        let hidDevices = eightBitDoDetector.detectedDevices
        guard !hidDevices.isEmpty else { return nil }
        // If at least one detected 8BitDo device is in a non-supported mode,
        // surface it. Apple mode controllers are also picked up by GCController,
        // so we only warn for the others.
        return hidDevices.first { !$0.mode.supportedByMacOS }
    }

    private var controllerStatusBar: some View {
        VStack(spacing: 0) {
            if let warning = eightBitDoModeWarning {
                eightBitDoWarningBanner(warning)
            }

            if controllerService.connectedControllers.isEmpty
                && controllerService.rawHIDGamepadSlots.isEmpty {
                HStack(spacing: 6) {
                    ControllerGlyph(height: 13)
                        .foregroundStyle(.secondary)
                    Text("No controllers connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                ForEach(Array(controllerService.connectedControllers.enumerated()), id: \.offset) { index, controller in
                    ControllerChipView(
                        controller: controller,
                        index: index,
                        color: Self.controllerColors[index % Self.controllerColors.count],
                        info: controllerService.controllerDetails[index],
                        onSetLight: { r, g, b in
                            controllerService.stopRGBCycle(at: index)
                            controllerService.setControllerLight(at: index, red: r, green: g, blue: b)
                        },
                        onSetBrightness: { brightness in
                            controllerService.setControllerBrightness(at: index, brightness: brightness)
                        },
                        onToggleRGB: {
                            controllerService.toggleRGBCycle(at: index)
                        },
                        isRGBActive: controllerService.rgbCycleActive[index] == true,
                        onRefresh: {
                            controllerService.refreshControllers()
                        },
                        onOpenExample: {
                            let brand = controllerService.controllerDetails[index]?.brand ?? .unknown
                            jumpToPreset(named: ExamplePresets.exampleName(for: brand))
                        },
                        rgbSpeed: $controllerService.rgbCycleSpeed
                    )
                }

                // Raw HID gamepads (8BitDo XInput, Xbox 360 wired,
                // Logitech F310/F710, generic descriptor-parsed pads).
                // They don't fit the MFi GCController chip (no battery,
                // no light bar), so render a simpler chip per slot.
                ForEach(rawHIDSortedSlots, id: \.slot) { entry in
                    rawHIDChip(slot: entry.slot, gamepad: entry.gamepad)
                }
            }

            // The "● Active" status pill that used to live here was
            // redundant: the same state is already shown by the green
            // dot next to the active preset in the sidebar, by the
            // Deactivate button in the preset detail header, AND by
            // the menu bar icon's dropdown. Three indicators for the
            // same fact was visual noise.
        }
        .background(.clear)
    }

    /// Sorted (slot index, gamepad) pairs for the raw HID controllers
    /// rendered in the status bar. Stable ordering keeps the chip
    /// layout from jittering when the dictionary's hash order changes.
    private var rawHIDSortedSlots: [(slot: Int, gamepad: RawHIDGamepad)] {
        return controllerService.rawHIDGamepadSlots
            .map { (slot: $0.key, gamepad: $0.value) }
            .sorted { $0.slot < $1.slot }
    }

    @ViewBuilder
    private func rawHIDChip(slot: Int, gamepad: RawHIDGamepad) -> some View {
        let color = Self.controllerColors[slot % Self.controllerColors.count]
        HStack(spacing: 8) {
            ControllerGlyph(height: 11)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(gamepad.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("Slot \(slot + 1)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("Raw HID")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }

            Spacer()

            Text(gamepad.transport)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func eightBitDoWarningBanner(_ device: EightBitDoDevice) -> some View {
        // If InputConfig's raw-HID layer is already reading this
        // controller directly, the warning is misleading - the device
        // is fully usable in its current mode. Suppress the banner.
        let isHandledByRawHID = controllerService.rawHIDGamepadSlots.values
            .contains { $0.vendorID == EightBitDoDetector.vendorID
                && $0.productID == device.productID }

        if !isHandledByRawHID {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("8BitDo controller detected in \(device.mode.rawValue) mode")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Text(eightBitDoGuidance(for: device))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Help") {
                    HelpGuideWindowController.shared.show()
                }
                .buttonStyle(.solidSecondaryCompact)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
        }
    }

    /// Tailored mode-switch guidance per model. Some 8BitDo controllers
    /// have no physical mode switch and a few (e.g. Ultimate 2C wired)
    /// have no Apple mode at all, so the generic "flip to A on the back"
    /// instruction was misleading users into thinking the app was broken.
    private func eightBitDoGuidance(for device: EightBitDoDevice) -> String {
        let name = device.productName.lowercased()
        if name.contains("ultimate 2c") || name.contains("ultimate2c") {
            return "The Ultimate 2C wired model has no Apple mode. Hold Y while plugging in USB to switch to Switch mode (macOS reads this natively), or update InputConfig - the latest build reads this controller directly in any mode."
        }
        if name.contains("ultimate") {
            return "Set the back switch to A for Apple mode. If your model has no slider, hold B while turning on for Apple mode. Switch mode (S) also works on macOS Ventura+."
        }
        return "Switch to Apple mode (A on the back of the controller) for full Mac support. If your model has no slider, hold B while turning on."
    }

    private var bottomToolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Preset") {
                    let preset = presetStore.createPreset()
                    selectedPresetId = preset.id
                    newlyCreatedPresetId = preset.id
                    editingPreset = preset
                }
                Button("New Group...") {
                    pendingGroupPresetIDs = []
                    newGroupName = "New Group"
                    // Use a dummy preset to drive the sheet item binding.
                    creatingGroupForPreset = presetStore.presets.first ?? Preset()
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Add")
            .accessibilityHint("Add a new preset or group")

            Spacer()

            Button {
                HelpGuideWindowController.shared.show()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11))
                    Text("Help")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Help")
            .accessibilityHint("Opens the in-app help guide")

            Link(destination: URL(string: "https://github.com/ryleighnewman/InputConfig")!) {
                Text("GitHub")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("GitHub")
            .accessibilityHint("Opens the project's GitHub repository in your browser")

            Button {
                TipJarWindowController.shared.show()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 11))
                    Text("Support")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Support development")
            .accessibilityHint("Opens the tip jar")

            Spacer()

            Button {
                showingImportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .spotlightAnchor(SpotlightID.importButton)
            .accessibilityLabel("Import preset")
            .accessibilityHint("Pick a preset JSON file to add to the library")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.clear)
        .fileImporter(
            isPresented: $showingImportSheet,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: true
        ) { result in
            // Hand the URLs to the review sheet instead of importing
            // silently. The user gets a chance to rename or skip each
            // entry, and broken files are surfaced with a specific
            // error message instead of vanishing.
            if case .success(let urls) = result {
                presetStore.previewImports(from: urls)
            }
        }
        .sheet(isPresented: Binding(
            get: { !presetStore.importReviewQueue.isEmpty },
            set: { if !$0 { presetStore.cancelImportReview() } }
        )) {
            ImportReviewSheet()
                .environmentObject(presetStore)
                .glassBackground()
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            // The scrolling detail content gets the canonical header fade so it
            // dissolves into the window vibrancy under the transparent titlebar
            // instead of colliding with the toolbar. Applied once here so both
            // PresetDetailView and welcomeView inherit it; the developer log
            // below sits outside the faded region.
            Group {
                if let presetId = selectedPresetId,
                   let preset = presetStore.presets.first(where: { $0.id == presetId }) {
                    PresetDetailView(
                        preset: presetBinding(for: preset),
                        onEdit: { editingPreset = preset },
                        onToggle: { togglePreset(preset) },
                        onJumpToBinding: { target in
                            pendingEditorJump = target
                            editingPreset = preset
                        }
                    )
                    .environmentObject(mappingEngine)
                    .environmentObject(controllerService)
                    .environmentObject(presetStore)
                    // Key the detail view to the preset identity. Without this,
                    // switching presets reuses the same view instance and the
                    // editable title TextField animates/morphs from the old
                    // name to the new one - with .title2 that mid-flight
                    // reflow renders as a "downward distortion" of the title.
                    // A stable id gives each preset a fresh header instead.
                    .id(presetId)
                } else {
                    welcomeView
                }
            }
            .headerFade()

            // Developer log, gated behind the Settings debug toggle.
            if showDebugLog {
                Divider()
                    .padding(.horizontal)
                DebugLogView()
                    .environmentObject(mappingEngine)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Welcome

    /// Shown in the detail area when no preset is selected. Acts as both a
    /// landing page and a feature index. Designed to be skim-able: an icon,
    /// a headline, a one-line subtitle, a feature grid, and a single call
    /// to action. Not a modal or popup - replaces the "Select a preset"
    /// placeholder when the user hasn't picked one yet.
    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Headline
                VStack(spacing: 10) {
                    ControllerGlyph(height: 42)
                        .foregroundStyle(.tertiary)
                    Text("Welcome to InputConfig")
                        .font(.title2.weight(.semibold))
                    Text("Control your Mac with a game controller or any input device. An accessible way to map controllers, keyboards, and mice to keyboard, mouse, MIDI, and more.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                // Quick actions, in two rows: the two creation buttons on top,
                // the two help / onboarding buttons underneath.
                VStack(spacing: 10) {
                    // Row 1: create a preset, or build one with the wizard.
                    HStack(spacing: 10) {
                        Button {
                            let preset = presetStore.createPreset()
                            selectedPresetId = preset.id
                            // Mark this as freshly-created so an editor
                            // Cancel deletes the empty draft instead of
                            // leaving it lingering in the sidebar.
                            newlyCreatedPresetId = preset.id
                            editingPreset = preset
                        } label: {
                            Label("Create New Preset", systemImage: "plus")
                        }
                        .buttonStyle(.solid)
                        .spotlightAnchor(SpotlightID.createNew)

                        // Smart Preset Maker: guided wizard, as a quiet secondary
                        // capsule so it doesn't overpower the creation action.
                        Button {
                            showingSmartMaker = true
                        } label: {
                            Label("Smart Preset Maker", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.solidSecondary)
                        .help("Answer a few quick questions and we'll build a tailored preset for your game, app, or workflow")
                    }

                    // Row 2: onboarding + docs, underneath the creation buttons.
                    HStack(spacing: 10) {
                        Button("Quick Start Guide") {
                            startTutorial()
                        }
                        // Sized to match the other welcome buttons. The hero
                        // glass CTA (GlassCTAButton) is reserved for standalone
                        // primary surfaces, not this grid of equal actions.
                        .buttonStyle(SolidButton(tint: .teal))
                        .help("Guided walkthrough of every major feature with click animations")

                        Button {
                            HelpGuideWindowController.shared.show()
                        } label: {
                            Label("Open Help Guide", systemImage: "questionmark.circle")
                        }
                        .buttonStyle(.solidSecondary)
                    }
                }

                // Feature grid - each card opens an animated demo sheet
                // explaining the feature, with a button to jump to a matching
                // example preset. Fixed 4-column layout so the 12 tutorials
                // form exactly 3 rows on any reasonable window width.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                    spacing: 12
                ) {
                    demoCard(kind: .keyboardMouse,
                             icon: "keyboard",
                             detail: "Map any button, trigger, or stick to keyboard keys, mouse buttons, mouse motion, or scroll wheel.",
                             tint: .orange)
                    demoCard(kind: .controllers,
                             icon: "gamecontroller.fill",
                             detail: "DualSense, DualShock 4, Xbox, Switch Pro, Joy-Cons, Stadia, 8BitDo, and any MFi gamepad.",
                             tint: .cyan)
                    demoCard(kind: .variableSensitivity,
                             icon: "slider.horizontal.below.rectangle",
                             detail: "Joystick depth scales output speed. Pick linear, smooth, or aggressive curves per binding.",
                             tint: .blue)
                    demoCard(kind: .deadzone,
                             icon: "scope",
                             detail: "Live joystick visualizer with a draggable trail and slider to find the perfect deadzone.",
                             tint: .green)
                    demoCard(kind: .toggleMode,
                             icon: "switch.2",
                             detail: "Press once to latch on, press again to release. Sticky modifiers, push-to-talk, auto-run.",
                             tint: .orange)
                    demoCard(kind: .macros,
                             icon: "bolt.fill",
                             detail: "Chain keystrokes with custom timing, or rapid-fire any button at a configurable rate.",
                             tint: .yellow)
                    demoCard(kind: .stackedOutputs,
                             icon: "square.stack.3d.up.fill",
                             detail: "One press fires key + click + MIDI + speech in parallel. Different from a macro - all at once, not in sequence.",
                             tint: .blue)
                    demoCard(kind: .touchpad,
                             icon: "rectangle.and.hand.point.up.left.fill",
                             detail: "DualSense and DualShock 4 touchpad surfaces can drive the mouse cursor.",
                             tint: .mint)
                    demoCard(kind: .gyro,
                             icon: "gyroscope",
                             detail: "Tilt-to-aim with the controller's gyroscope. Works on DualSense, DualSense Edge, and DualShock 4.",
                             tint: .teal)
                    demoCard(kind: .haptic,
                             icon: "waveform",
                             detail: "Vibrate the controller when a binding fires. Works with DualSense, DualSense Edge, and similar.",
                             tint: .purple)
                    demoCard(kind: .speech,
                             icon: "speaker.wave.2.fill",
                             detail: "Speak a custom phrase on press through Mac speakers or the controller speaker.",
                             tint: .indigo)
                    demoCard(kind: .lightBar,
                             icon: "light.beacon.max.fill",
                             detail: "Pick a color with the picker, set brightness, or run an RGB cycle on DualSense controllers.",
                             tint: .red)
                    demoCard(kind: .midi,
                             icon: "music.note.list",
                             detail: "Send Note, CC, and Pitch Bend through a virtual MIDI port to GarageBand, Logic, Ableton, and more.",
                             tint: .pink)
                    demoCard(kind: .midiCC,
                             icon: "dial.high.fill",
                             detail: "Sticks and triggers send continuous MIDI Control Change values. Soft knobs for your DAW.",
                             tint: .purple)
                    demoCard(kind: .autoLaunch,
                             icon: "app.badge.fill",
                             detail: "Per-preset Automation & Gaming Utilities: open an app on activate, confine the cursor, hide the system pointer.",
                             tint: .green)
                    demoCard(kind: .stats,
                             icon: "chart.bar.fill",
                             detail: "Lifetime counts of presses, motion, scrolls, and MIDI events with most-used inputs and presets. All local, no telemetry.",
                             tint: .brown)
                }
                .padding(.horizontal, 28)

                QuickTipsPill()
                    .padding(.horizontal, 40)

                Text("Plug in a controller to get started. Open the Help menu for setup guides for every supported device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Clickable feature card that opens the matching animated demo sheet.
    @ViewBuilder
    private func demoCard(kind: FeatureDemoKind, icon: String, detail: String, tint: Color) -> some View {
        FeatureCardButton(kind: kind, icon: icon, detail: detail, tint: tint,
                          isHighlighted: tutorialFeatureSpotlight == kind) {
            presentedDemoKind = kind
        }
        .modifier(ConditionalSpotlightAnchor(
            active: tutorialFeatureSpotlight == kind,
            id: SpotlightID.welcomeCard))
    }

    /// Stand-alone home-screen feature card with the same hover lift /
    /// tint / scale treatment the Statistics dashboard uses on its
    /// tiles. Lifted out of `demoCard` because tracking a hover state
    /// requires its own `@State`, and embedding @State inside a
    /// `@ViewBuilder func` doesn't compose well.
    private struct FeatureCardButton: View {
        let kind: FeatureDemoKind
        let icon: String
        let detail: String
        let tint: Color
        let isHighlighted: Bool
        let onTap: () -> Void
        @State private var hovering: Bool = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            // TimelineView gives us a continuous time stream so the
            // spotlight pulse actually loops while `isHighlighted` is
            // true. (`.animation(...repeatForever..., value:)` keyed
            // on a Bool only fires on the transition and doesn't
            // actually animate - SwiftUI sees no value change to
            // interpolate against, so the card just sat there.)
            // Reduce Motion pauses the timeline and pins the pulse at
            // fully highlighted instead of looping.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !isHighlighted || reduceMotion)) { context in
                let pulse: Double = {
                    guard isHighlighted else { return 0 }
                    if reduceMotion { return 1.0 }
                    return (sin(context.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2
                }()
                Button(action: onTap) {
                    cardLabel(pulse: pulse)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering = $0 }
            }
        }

        @ViewBuilder
        private func cardLabel(pulse: Double) -> some View {
            // Pre-compute everything that depends on `pulse` so the
            // modifier chain sees plain Color / CGFloat / Double
            // values. Inline ternary arithmetic was timing out the
            // type-checker.
            let fillColor: Color = {
                if isHighlighted { return tint.opacity(0.18 + 0.18 * pulse) }
                if hovering { return tint.opacity(0.16) }
                return Color.clear
            }()
            let strokeColor: Color = {
                if isHighlighted { return tint.opacity(0.7 + 0.3 * pulse) }
                if hovering { return tint.opacity(0.55) }
                return Color.clear
            }()
            let strokeWidth: CGFloat = isHighlighted
                ? CGFloat(1.5 + pulse)
                : 1
            let shadowColor: Color = isHighlighted
                ? tint.opacity(0.3 + 0.5 * pulse)
                : Color.clear
            let shadowRadius: CGFloat = isHighlighted
                ? CGFloat(8.0 + 8.0 * pulse)
                : 0
            let scale: CGFloat = {
                if reduceMotion { return 1.0 }
                if isHighlighted { return CGFloat(1.0 + 0.05 * pulse) }
                if hovering { return 1.02 }
                return 1.0
            }()
            // Tint only lights up on hover or while the tour highlights
            // the card. At rest every tile's icon is neutral grey, so the
            // grid reads as one calm surface instead of a wall of colour.
            let active: Bool = hovering || isHighlighted
            let iconColor: Color = active ? tint : Color.secondary.opacity(0.55)
            let chevronTint: Color = active ? tint : Color.secondary.opacity(0.45)
            return HStack(alignment: .top, spacing: 10) {
                IconView(name: icon, glyphHeight: 14)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(kind.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "play.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(chevronTint)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
            .shadow(color: shadowColor, radius: shadowRadius)
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Helper because `.spotlightAnchor(...)` can't be conditionally
    /// applied directly inside a ViewBuilder; use a ViewModifier.
    private struct ConditionalSpotlightAnchor: ViewModifier {
        let active: Bool
        let id: String
        func body(content: Content) -> some View {
            if active {
                content.spotlightAnchor(id)
            } else {
                content
            }
        }
    }

    // MARK: - Helpers

    private func presetBinding(for preset: Preset) -> SwiftUI.Binding<Preset> {
        SwiftUI.Binding(
            get: { presetStore.presets.first(where: { $0.id == preset.id }) ?? preset },
            set: { newValue in
                presetStore.savePreset(newValue)
            }
        )
    }

    // MARK: - Actions

    /// Queue the preset for delete confirmation. The dialog is wired up via
    /// the main body's `.confirmationDialog(presenting:)`.
    private func confirmDelete(_ preset: Preset) {
        presetPendingDelete = preset
    }

    // MARK: - Quick Start tutorial

    /// Close any sheets opened by tutorial steps when the tour ends.
    /// Wired up through TutorialPlumbing so the heavy body chain doesn't
    /// hold yet another onChange.
    private func handleTutorialEnded() {
        tutorialFeatureSpotlight = nil
        editingPreset = nil
        showingMotionCalibrationFromMenu = false
        showingTouchpadCalibrationFromMenu = false
    }

    /// Kick off the guided tour. The first step's action fires immediately
    /// so the app responds the moment the user clicks "Start Tutorial".
    /// Pulled out of the `.sheet(onDismiss:)` closure inline because
    /// stacking too many `.onChange` / `.onReceive` modifiers on the
    /// same view plus an inline multi-statement dismiss handler made
    /// SwiftUI's type-checker time out. As a plain method the body
    /// resolves instantly.
    private func handleEditorDismiss() {
        // If the user cancelled a newly created preset, delete it.
        // The hardDelete path skips trash so a "create + cancel"
        // cycle doesn't litter the Recently Deleted buffer with
        // empty drafts. The lookup is forgiving - if for any reason
        // the row is already gone we silently no-op instead of
        // crashing on a force-unwrap.
        if let newId = newlyCreatedPresetId {
            if let draft = presetStore.presets.first(where: { $0.id == newId }) {
                // Only discard PRISTINE drafts. If the user scanned or added
                // any bindings before pressing Escape, keep the preset;
                // hard-deleting it threw away real setup work.
                let isPristine = draft.joysticks.allSatisfy { $0.bindings.isEmpty }
                if isPristine {
                    presetStore.hardDeletePreset(draft)
                    if selectedPresetId == newId { selectedPresetId = nil }
                }
            } else if selectedPresetId == newId {
                selectedPresetId = nil
            }
            newlyCreatedPresetId = nil
        }
        // Resume outputs when the editor closes.
        mappingEngine.outputsPaused = false
        engineWasRunningBeforeEdit = false
        // Clear any pending jump so re-opening the editor doesn't reuse
        // a stale target.
        pendingEditorJump = nil
    }

    private func startTutorial() {
        // Make sure the welcome page is showing so the demo cards are
        // visible to spotlight.
        selectedPresetId = nil
        showingStats = false
        editingPreset = nil
        showingMotionCalibrationFromMenu = false
        showingTouchpadCalibrationFromMenu = false
        // Collapse the debug log so the welcome feature grid + Quick
        // Tour have full vertical room. The DebugLogView reads the
        // same @AppStorage key so this takes effect immediately.
        UserDefaults.standard.set(false, forKey: "InputConfig.debugLogExpanded")
        // Inject a synthetic DualSense Edge so all the visualizer
        // widgets (sticks / triggers / gyro / touchpad / paddles /
        // light bar) render during the tour even with no real
        // hardware plugged in. Cleaned up when the user finishes or
        // skips.
        controllerService.enableTutorialFakeController()
        tutorialState.start(steps: tutorialSteps)
    }

    /// Pick the first non-empty preset we can find. Used by the tutorial
    /// to land the user on something meaningful even if their first
    /// preset is empty.
    private func tutorialDemoPreset() -> Preset? {
        return presetStore.presets.first(where: { !$0.joysticks.isEmpty })
            ?? presetStore.presets.first
    }

    /// Pull the Minecraft seeded preset so the interactive walkthrough
    /// at the end of the tour has a concrete target. Falls back to any
    /// preset that mentions "Minecraft" in its name, then to the first
    /// non-empty preset, so the tour never dead-ends on a missing
    /// seed.
    private func tutorialMinecraftPreset() -> Preset? {
        if let p = presetStore.presets.first(where: { $0.name == "Minecraft" }) {
            return p
        }
        if let p = presetStore.presets.first(where: {
            $0.name.lowercased().contains("minecraft")
        }) {
            return p
        }
        return tutorialDemoPreset()
    }

    /// Tutorial helper: set the given preset's slot's inputKind via
    /// the store. Used by the Live Visualizer step to flip the demo
    /// preset's first slot into controller mode so the visualizer
    /// shows controller widgets even when no controller is connected.
    /// Idempotent - calling with the same kind a second time is a
    /// no-op write (still touches modifiedAt but harmless).
    fileprivate func tutorialSetSlotKind(presetID: UUID,
                                         slot: Int,
                                         kind: SlotInputKind) {
        guard var updated = presetStore.presets.first(where: { $0.id == presetID })
            else { return }
        while updated.joysticks.count <= slot {
            updated.joysticks.append(JoystickMapping(tag: ""))
        }
        updated.joysticks[slot].inputKind = kind
        updated.modifiedAt = Date()
        presetStore.savePreset(updated)
    }

    /// Sequence of guided steps. Each action mutates ContentView state so
    /// the user sees the live app respond as the tour progresses; the
    /// spotlight references named anchors that ContentView attaches to
    /// the matching UI elements.
    private var tutorialSteps: [TutorialStep] {
        [
            TutorialStep(
                icon: "sparkles",
                tint: .teal,
                title: "Welcome to InputConfig",
                body: "This guided tour takes about a minute and walks through every major feature. We'll light up parts of the app as we go and show short animated examples. Hit Next to begin.",
                action: {
                    selectedPresetId = nil
                    showingStats = false
                }
            ),
            TutorialStep(
                icon: "house.fill",
                tint: .blue,
                title: "Home, Stats, and Settings",
                body: "The toolbar (top of the window) has three buttons: Home returns to this welcome page, the chart icon opens detailed Statistics, and the gear opens Settings.",
                spotlight: SpotlightID.homeButton,
                spotlightShape: .circle,
                tip: "Quick keyboard shortcuts: \u{2318}0 for Stats, \u{2318}, for Settings.",
                action: { selectedPresetId = nil }
            ),
            TutorialStep(
                icon: "list.bullet.rectangle",
                tint: .indigo,
                title: "Your preset library",
                body: "The sidebar lists every preset you've created, organized into groups. Each preset is one mapping configuration. Click the ellipsis icon next to a truncated description to read its full text.",
                spotlight: SpotlightID.sidebar,
                tip: "Drag a preset onto another to create a new group. Right-click for Activate / Edit / Duplicate / Delete.",
                action: { selectedPresetId = nil }
            ),
            TutorialStep(
                icon: "books.vertical.fill",
                tint: .orange,
                title: "Example presets to learn from",
                body: "Below the toolbar is a grid of feature cards. Each opens a live animated demo and links to a working example preset. Watch the cursor land on the pulsing one.",
                spotlight: SpotlightID.welcomeCard,
                tip: "Click the highlighted card to open its full animated demo + jump to the matching example preset.",
                action: {
                    selectedPresetId = nil
                    editingPreset = nil
                    // Pulse the gyro card first, then send the
                    // simulated cursor to land on it so the user sees
                    // exactly which tile we mean.
                    tutorialFeatureSpotlight = .gyro
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.welcomeCard
                        ) {
                            // Don't actually open the demo sheet -
                            // we're just visually pointing the user at
                            // the right card.
                        }
                    }
                }
            ),

            // ─── Open a preset and walk through the editor first ───

            TutorialStep(
                icon: "rectangle.fill.on.rectangle.fill",
                tint: .teal,
                title: "Preset detail page",
                body: "Watch the cursor glide to the sidebar and click a real preset. The detail page shows usage stats, controller capabilities, storage location, version history, an Activate button, and the Live Visualizer at the bottom.",
                spotlight: SpotlightID.sidebar,
                action: {
                    tutorialFeatureSpotlight = nil
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.sidebar
                    ) {
                        if let p = tutorialDemoPreset() {
                            selectedPresetId = p.id
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .indigo,
                title: "Edit the Preset",
                body: "Watch the cursor click the Edit button. The editor opens. Each row is one binding: Scan an input, then pick what it outputs (key, mouse, MIDI, macro, speech, more).",
                spotlight: SpotlightID.editButton,
                tip: "The engine pauses while the editor is open so scanning a key never fires it.",
                action: {
                    if let p = tutorialDemoPreset() {
                        selectedPresetId = p.id
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.editButton
                        ) {
                            editingPreset = p
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "bolt.fill",
                tint: .yellow,
                title: "Macros, turbo, and other Options",
                body: "Auto-expanding the first row's Options for you. Deadzone, Sensitivity, Variable Sensitivity, Toggle, Turbo, Macro chain, Spoken text, plus per-binding light and haptic overrides all live here.",
                demo: .macroChain,
                tip: "The same row supports stacked outputs. Click the + on the right to fire a key, click, and MIDI note from one press.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToFirstBinding, object: nil)
                    // After a brief pause for the scroll to land, ask
                    // the first row to expand its Options disclosure.
                    // It uses its own internal @State so this is the
                    // only way to drive it from outside.
                    if let firstID = tutorialDemoPreset()?
                        .joysticks.first?.bindings.first?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            NotificationCenter.default.post(
                                name: .inputConfigExpandBindingOptions,
                                object: firstID)
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "tray.and.arrow.down.fill",
                tint: .blue,
                title: "Save, then close",
                body: "The Save and Cancel buttons sit at the bottom right of the editor sheet. Watch the cursor land on Save. The Modified timestamp updates the moment it fires. Then the cursor moves to Cancel.",
                spotlight: SpotlightID.editorSave,
                tip: "Cancel on a freshly-created preset hard-deletes it, with no Recently Deleted entry.",
                action: {
                    // Sequence: cursor to Save → 1.4s pause → cursor
                    // to Cancel → 0.6s pause → actually dismiss the
                    // editor. The user sees three discrete beats so
                    // each "click" registers.
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.editorSave
                    ) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            TutorialState.shared.simulateClickThen(
                                at: SpotlightID.editorCancel
                            ) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    withAnimation { editingPreset = nil }
                                }
                            }
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "play.fill",
                tint: .green,
                title: "Activate the preset",
                body: "Watch the cursor click the green Activate button. The engine starts. The light bar switches to this preset's color. Cursor utilities (confine, auto-recenter, hide) and the auto-launch app from Automation & Gaming Utilities all kick in. Click again to stop.",
                spotlight: SpotlightID.activateButton,
                tip: "Click the green dot in the sidebar next to a preset to toggle activation without opening the detail page.",
                action: {
                    editingPreset = nil
                    // Brief beat after the editor closes (previous step
                    // may have just dismissed it) before the cursor
                    // flies over.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.activateButton
                        ) {
                            // Don't actually toggle - just point the
                            // user at the button. They activate when
                            // ready themselves.
                        }
                    }
                }
            ),

            // ─── Now show the Live Visualizer and its features ─────

            TutorialStep(
                icon: "gamecontroller.fill",
                tint: .teal,
                title: "Live Visualizer",
                body: "Scrolling you down to the Live Visualizer. It mirrors your physical controller in real time. Press a button, move a stick, or tilt the gyro and everything shows up here. Click any widget to inspect what it's bound to.",
                spotlight: SpotlightID.visualizer,
                demo: .buttonMapping,
                tip: "Use the +/- zoom slider in the visualizer header to resize the panel.",
                action: {
                    editingPreset = nil
                    // Auto-scroll the detail panel to the visualizer
                    // section. PresetDetailView listens for this and
                    // also expands the DisclosureGroup.
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToVisualizer, object: nil)
                }
            ),
            TutorialStep(
                icon: "rectangle.3.group",
                tint: .blue,
                title: "Template picker, controller mode",
                body: "The visualizer can swap between controller widgets, a full macOS keyboard map, or a mouse diagram. I'm temporarily forcing the controller template here so you can see all the gamepad-specific widgets even without one connected.",
                spotlight: SpotlightID.templatePicker,
                tip: "Set per-slot from the editor too; the picker is a quick-switch at the visualizer level.",
                action: {
                    // Force controller layout on the demo preset's
                    // first slot so the next several steps have widgets
                    // to point at.
                    if let p = tutorialDemoPreset() {
                        tutorialSetSlotKind(presetID: p.id, slot: 0, kind: .controller)
                    }
                }
            ),
            TutorialStep(
                icon: "dot.circle.and.hand.point.up.left.fill",
                tint: .blue,
                title: "Analog sticks, click them in the visualizer",
                body: "The two stick widgets in the controller layout you can see now report continuous -1 to +1 values per axis, perfect for cursor speed, scroll speed, or anything proportional. Click a stick widget in the visualizer for the bound bindings + a jump-to-editor button.",
                demo: .analogStick,
                tip: "Pick from Linear, Smooth, or Aggressive curves in the editor's Advanced section."
            ),
            TutorialStep(
                icon: "arrow.up.and.down.text.horizontal",
                tint: .orange,
                title: "Triggers, pressure sensitive",
                body: "Trigger widgets show analog magnitude with the orange tick marking the binding's deadzone threshold. Click a trigger widget for its bindings popover. Use Variable Sensitivity in the editor to scale output speed by how hard you press.",
                demo: .pressureTrigger
            ),
            TutorialStep(
                icon: "gyroscope",
                tint: .purple,
                title: "Gyroscope motion",
                body: "Controllers with motion sensors (DualSense, DualShock 4, Switch Pro, Joy-Con) expose gyro + accelerometer data. The motion widget shows the controller orientation; clicking it offers Reset gyroscope to re-zero drift without leaving the visualizer.",
                demo: .gyro,
                tip: "Run Calibrate Motion once per controller so drift is corrected from the start."
            ),
            TutorialStep(
                icon: "pencil.and.outline",
                tint: .blue,
                title: "Edit Layout",
                body: "Watch the cursor click Edit Layout. The visualizer flips into 'blueprint mode' with a faint grid and a dashed yellow outline around every widget. Drag any widget to rearrange it.",
                spotlight: SpotlightID.customizeButton,
                tip: "Click Reset (in edit mode) to put every widget back where it started.",
                action: {
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.customizeButton
                    ) {
                        // No-op - the user can toggle it themselves
                        // when they want to actually drag widgets.
                    }
                }
            ),
            TutorialStep(
                icon: "light.beacon.max.fill",
                tint: .pink,
                title: "Per-preset light bar",
                body: "DualSense and DualShock 4 have a light bar. The strip across the top of the visualizer lets you pick a color that's applied automatically while this preset is active. Click it to open the color picker. Deactivating the preset reverts the light.",
                spotlight: SpotlightID.lightBarStrip,
                demo: .lightBar
            ),
            TutorialStep(
                icon: "note.text",
                tint: .yellow,
                title: "Per-preset notes",
                body: "Below the visualizer is a free-form notes field. Use it to remember which game this preset is for, gotchas, control schemes, anything. Markdown isn't supported; plain text only.",
                spotlight: SpotlightID.notesSection
            ),
            TutorialStep(
                icon: "gyroscope",
                tint: .purple,
                title: "Calibrate Motion / Gyro",
                body: "Reach Calibrate Motion from the Controller menu (top of the screen). Place the controller flat, click Start Calibration, hold still for 2 s. Run once per controller; the recorded zero is per-device.",
                action: {
                    editingPreset = nil
                    showingTouchpadCalibrationFromMenu = false
                    // Brief beat so a previously-open sheet has time to
                    // dismiss before we present the next one - otherwise
                    // SwiftUI quietly skips the second presentation.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showingMotionCalibrationFromMenu = true
                    }
                }
            ),
            TutorialStep(
                icon: "rectangle.and.hand.point.up.left.fill",
                tint: .mint,
                title: "Calibrate Touchpad",
                body: "Touchpad Setup opens with a device picker at the top: DualSense, DualShock 4, or Mac Trackpad. Pick one, then sweep the surface to calibrate, or jump to Regions to define tap zones bound to keys.",
                action: {
                    showingMotionCalibrationFromMenu = false
                    // Brief delay so the previous sheet visibly closes
                    // before we open the next one - otherwise it looks
                    // like the same sheet just changed contents.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showingTouchpadCalibrationFromMenu = true
                    }
                }
            ),
            TutorialStep(
                icon: "chart.line.uptrend.xyaxis",
                tint: .purple,
                title: "Lifetime statistics",
                body: "The chart icon at the top of the window opens Statistics: lifetime usage, time connected, button presses, mouse pixels, top presets, and more. Click any tile for a detailed breakdown.",
                spotlight: SpotlightID.statsButton,
                spotlightShape: .circle,
                tip: "All stats are stored locally. Nothing leaves your Mac.",
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    editingPreset = nil
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.statsButton
                    ) {
                        showingStats = true
                    }
                }
            ),
            TutorialStep(
                icon: "gear",
                tint: .gray,
                title: "Settings & backup",
                body: "The gear icon opens Settings with Launch-at-Login, controller diagnostics, About, a Gaming Utilities panel, full Export Backup / Restore from Backup, and the App Store / open-source links. Cursor flies to the gear so you see where it is.",
                spotlight: SpotlightID.settingsButton,
                spotlightShape: .circle,
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    editingPreset = nil
                    showingStats = false
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.settingsButton
                    ) {
                        showingSettingsSheet = true
                    }
                }
            ),
            TutorialStep(
                icon: "questionmark.circle.fill",
                tint: .cyan,
                title: "Help guides",
                body: "Dismissing Settings for you. The Help menu (\u{2318}?) opens an in-app guide with deeper docs on every feature, plus a separate Test Bench. The Quick Start Tour itself is in there too if you ever want to repeat it.",
                action: {
                    showingMotionCalibrationFromMenu = false
                    showingTouchpadCalibrationFromMenu = false
                    editingPreset = nil
                    // The previous Settings step left the sheet open;
                    // close it before the Help menu reference makes
                    // sense to the user.
                    showingSettingsSheet = false
                    showingStats = false
                }
            ),
            TutorialStep(
                icon: "tray.and.arrow.down",
                tint: .blue,
                title: "Importing other presets",
                body: "Use the download icon at the bottom right of the sidebar to import preset JSON files. The Import Review sheet previews each file with a rename field, parse-error messages, and per-row skip. Nothing lands without confirmation.",
                spotlight: SpotlightID.importButton,
                tip: "Drag preset JSONs straight onto the icon to import them too.",
                action: {
                    showingSettingsSheet = false
                    showingStats = false
                }
            ),

            // ─── Interactive Minecraft walkthrough ─────────────────
            // From here on the tour stops *explaining* the app in
            // abstract terms and starts driving it. Each action()
            // closure mutates ContentView's @State so the user sees
            // the real UI respond - sidebar selection, editor sheet
            // opening, scrolling to specific binding rows, expanding
            // their Options disclosure - exactly what they would do
            // themselves when building a Minecraft preset from scratch.

            TutorialStep(
                icon: "cube.fill",
                tint: .green,
                title: "Hands-on: build a Minecraft preset",
                body: "Now the focused part. Instead of repeating things you already saw, we'll dig into the two trickiest parts of any preset: SCANNING a binding (recording a controller input) and BUILDING a MACRO (chaining keystrokes off one button). Both happen inside the editor for the Minecraft preset.",
                action: {
                    selectedPresetId = nil
                    editingPreset = nil
                    showingSettingsSheet = false
                    showingStats = false
                }
            ),
            TutorialStep(
                icon: "list.bullet.rectangle.portrait",
                tint: .teal,
                title: "Select the Minecraft preset",
                body: "Cursor goes to the sidebar, clicks Minecraft. The detail page loads with its 24 bindings, the DualSense Edge in the slot (synthetic for this tour), and the Minecraft automation rules already wired up.",
                spotlight: SpotlightID.sidebar,
                action: {
                    editingPreset = nil
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.sidebar
                    ) {
                        if let mc = tutorialMinecraftPreset() {
                            selectedPresetId = mc.id
                            NotificationCenter.default.post(
                                name: .inputConfigScrollToPreset,
                                object: mc.id)
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .orange,
                title: "Open the editor",
                body: "Cursor clicks Edit. The binding editor slides up over the detail page. The engine outputs pause automatically, so scanning a key here records it as a binding instead of firing a real keystroke.",
                spotlight: SpotlightID.editButton,
                action: {
                    if let mc = tutorialMinecraftPreset() {
                        selectedPresetId = mc.id
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.editButton
                        ) {
                            editingPreset = mc
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "rectangle.dashed",
                tint: .indigo,
                title: "Anatomy of a binding row",
                body: "Each row is one binding. Left to right: drag handle, Scan, Input Type, Input Index, Direction, then the arrow, then Output Type and Value, plus the add, duplicate, and delete cluster.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToFirstBinding, object: nil)
                }
            ),
            TutorialStep(
                icon: "dot.scope",
                tint: .red,
                title: "Scanning: record a binding from your controller",
                body: "Click Scan on a row. It glows for 5 seconds. Press the button, move the stick, or tilt the gyro you want to bind. The row fills in. Same scan works with external keyboards and mice.",
                tip: "Hold Shift or Cmd while scanning to add that modifier to the recorded input."
            ),
            TutorialStep(
                icon: "bolt.fill",
                tint: .yellow,
                title: "Macros: chain keystrokes off one button",
                body: "Auto-expanding the first row's Options again. Toggle Macro on to reveal a steps editor. Each step is one event plus an optional delay. The whole chain fires on press.",
                tip: "Combine Macro with a Toggle binding to flip a series on or off with one button.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToFirstBinding, object: nil)
                    if let firstID = tutorialMinecraftPreset()?
                        .joysticks.first?.bindings.first?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            NotificationCenter.default.post(
                                name: .inputConfigExpandBindingOptions,
                                object: firstID)
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "plus.circle.fill",
                tint: .green,
                title: "Stacked outputs: one press, many actions",
                body: "The small + at the right of every binding row adds another output to the same input. One press can fire a key, a click, a MIDI note, and a spoken phrase together with independent per-output settings.",
                tip: "Use the X next to each output to delete it without touching the rest of the stack."
            ),
            TutorialStep(
                icon: "slider.horizontal.3",
                tint: .gray,
                title: "Automation & Gaming Utilities: per-preset side effects",
                body: "Scrolling down to Automation & Gaming Utilities. Fill in a launch path to auto-open the app on activate. Confine, auto-recenter, and Hide cursor toggles apply only while this preset is active.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToAutomation, object: nil)
                }
            ),
            TutorialStep(
                icon: "tray.and.arrow.down.fill",
                tint: .blue,
                title: "Save the Minecraft preset",
                body: "Cursor flies to Save (bottom right of the editor toolbar), then to Cancel, then the editor slides closed. Modified time updates, and the new bindings are on disk.",
                spotlight: SpotlightID.editorSave,
                action: {
                    TutorialState.shared.simulateClickThen(
                        at: SpotlightID.editorSave
                    ) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            TutorialState.shared.simulateClickThen(
                                at: SpotlightID.editorCancel
                            ) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    withAnimation { editingPreset = nil }
                                }
                            }
                        }
                    }
                }
            ),
            TutorialStep(
                icon: "play.circle.fill",
                tint: .green,
                title: "Activate Minecraft mode",
                body: "Scrolling back up to the Activate button. Click it for real to start the engine, launch Minecraft, hide the cursor, and turn the lightbar green.",
                spotlight: SpotlightID.activateButton,
                tip: "Cmd-click the green dot in the sidebar to toggle activation without leaving the home screen.",
                action: {
                    NotificationCenter.default.post(
                        name: .inputConfigScrollToTop, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        TutorialState.shared.simulateClickThen(
                            at: SpotlightID.activateButton
                        ) {
                            // No-op - user activates when they're ready
                            // to launch Minecraft.
                        }
                    }
                }
            ),

            // ─── Wrap-up ───────────────────────────────────────────

            TutorialStep(
                icon: "books.vertical.fill",
                tint: .orange,
                title: "Browse the example library",
                body: "Back on the home screen. The feature card grid is also a library. Every card opens an animated demo and links to a working example preset you can copy.",
                tip: "Each example preset is editable. Duplicate one as a starting point for your own.",
                action: {
                    selectedPresetId = nil
                    editingPreset = nil
                    showingStats = false
                    showingSettingsSheet = false
                    tutorialFeatureSpotlight = nil
                }
            ),
            TutorialStep(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "You're all set",
                body: "That's the full tour. You can now scan a binding, chain a macro, stack outputs, and set automation. Re-run any time from the Quick Start Guide button.",
                action: {
                    selectedPresetId = nil
                    editingPreset = nil
                }
            )
        ]
    }

    /// Actually delete the queued preset. The store moves it to the
    /// on-disk trash where the sidebar's Trash section can restore it
    /// at any time.
    private func performPendingDelete() {
        guard let preset = presetPendingDelete else { return }
        if selectedPresetId == preset.id { selectedPresetId = nil }
        // Stop the mapping engine BEFORE removing the preset. Earlier
        // versions called deletePreset → deactivateAll, which only
        // cleared the active flag but left the engine polling the now-
        // deleted preset, firing ghost outputs until the user stopped
        // it manually.
        if preset.isActive {
            mappingEngine.stop()
        }
        presetStore.deletePreset(preset)
        presetPendingDelete = nil
    }

    private func togglePreset(_ preset: Preset) {
        if preset.isActive {
            mappingEngine.stop()
            presetStore.deactivateAll()
            return
        }
        if preset.joysticks.isEmpty { return }
        // Gate: if this preset uses motion / touchpad bindings, ensure the
        // user has run the corresponding calibration. Missing calibration
        // makes the cursor / aim feel wrong on a brand-new controller.
        let needs = calibrationRequirements(for: preset)
        if needs.needsMotion || needs.needsTouchpad {
            pendingActivation = (preset: preset, reqs: needs)
            return
        }
        startEngine(with: preset)
    }

    private func startEngine(with preset: Preset) {
        // An empty preset cannot do anything; activating it would show the
        // green active state over an engine with nothing to run.
        guard preset.joysticks.contains(where: { !$0.bindings.isEmpty }) else { return }
        mappingEngine.stop()
        presetStore.activatePreset(preset)
        mappingEngine.start(with: preset)
        // A preset that emits keyboard/mouse output needs Accessibility for
        // that output to reach other apps. If it isn't granted yet, prompt
        // the user the moment they activate such a preset.
        accessibility.refresh()
        if !accessibility.isTrusted, presetUsesKeyboardOrMouse(preset) {
            showAccessibilityAlert = true
        }
    }

    /// True if any binding in the preset outputs a keyboard or mouse action -
    /// the outputs that require Accessibility. MIDI, haptics, and speech do not.
    private func presetUsesKeyboardOrMouse(_ preset: Preset) -> Bool {
        for joystick in preset.joysticks {
            for binding in joystick.bindings {
                for output in binding.outputs {
                    switch output.type {
                    case .key, .mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep:
                        return true
                    default:
                        continue
                    }
                }
            }
        }
        return false
    }

    /// The currently-active preset, if any.
    private var runningPreset: Preset? {
        presetStore.presets.first(where: { $0.isActive })
    }

    /// Reassuring, proactive Accessibility explainer shown on launch when the
    /// permission isn't granted. Spells out exactly why the app needs it, that
    /// the use is Apple-approved for accessibility, and that nothing leaves the
    /// Mac, so people feel safe granting it and their mappings actually work.
    @ViewBuilder
    private var accessibilityIntroSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "accessibility")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    Circle().fill(
                        LinearGradient(colors: [.blue, .indigo],
                                       startPoint: .top, endPoint: .bottom)
                    )
                )
                .padding(.top, 6)

            Text("Turn On Accessibility")
                .font(.title2.weight(.bold))

            Text("InputConfig uses macOS Accessibility to deliver the keyboard and mouse actions your controller is mapped to. This access has been approved by Apple for accessibility purposes and will allow additional functionality in the app. Your inputs stay on your Mac and are never sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("System Settings, Privacy & Security, Accessibility, then switch on InputConfig.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button {
                    // requestAccess registers the app's row in the
                    // Accessibility pane and shows the system prompt.
                    // Only opening the pane landed users in a list with
                    // no InputConfig row to turn on.
                    accessibility.requestAccess()
                    showingAccessibilityIntro = false
                } label: {
                    Text("Turn On Accessibility")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.solid)

                Button("Maybe Later") { showingAccessibilityIntro = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Toggle("Don't remind me again", isOn: $suppressAccessibilityIntro)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(28)
        .frame(width: 430)
    }

    /// Top-of-window banner shown while a keyboard/mouse preset is active but
    /// Accessibility hasn't been granted, so the user sees why their mappings
    /// aren't landing and can fix it in one click. Collapses to nothing
    /// otherwise (zero-height safe-area inset).
    @ViewBuilder
    private var accessibilityBanner: some View {
        if !accessibility.isTrusted,
           let active = runningPreset, presetUsesKeyboardOrMouse(active) {
            HStack(spacing: 10) {
                Image(systemName: "accessibility")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility access needed")
                        .font(.caption.weight(.semibold))
                    Text("Turn on InputConfig in Privacy & Security → Accessibility to send keyboard & mouse input.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.92))
                }
                Spacer(minLength: 8)
                Button("Open Settings") { accessibility.openSystemSettings() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange)
        }
    }

    private struct CalibrationRequirements {
        var needsMotion: Bool
        var needsTouchpad: Bool
        var connectedMotionControllerUncalibrated: Bool
        var touchpadUncalibrated: Bool
    }

    /// Inspect the preset's bindings + the currently connected hardware and
    /// decide what calibration prompts (if any) are needed before activation.
    private func calibrationRequirements(for preset: Preset) -> CalibrationRequirements {
        let allBindings = preset.joysticks.flatMap(\.bindings)
        let usesMotion = allBindings.contains { $0.input.type == .motion }
        let usesTouchpad = allBindings.contains {
            $0.input.type == .touchpad || $0.input.type == .touchpadRegion
        }

        // Motion: needs calibration if any motion-capable connected
        // controller hasn't been calibrated yet.
        var motionUncalibrated = false
        if usesMotion {
            for controller in controllerService.connectedControllers {
                if controller.motion != nil {
                    let key = MotionCalibrationService.identityKey(for: controller)
                    if !MotionCalibrationService.shared.isCalibrated(forKey: key) {
                        motionUncalibrated = true
                        break
                    }
                }
            }
        }

        // Touchpad: needs calibration if no saved bounds exist.
        let touchpadUncalibrated = usesTouchpad
            && !TouchpadService.shared.currentCalibration().isUserCalibrated

        return CalibrationRequirements(
            needsMotion: usesMotion && motionUncalibrated,
            needsTouchpad: touchpadUncalibrated,
            connectedMotionControllerUncalibrated: motionUncalibrated,
            touchpadUncalibrated: touchpadUncalibrated
        )
    }

    private func exportPreset(_ preset: Preset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name).json"
        if panel.runModal() == .OK, let url = panel.url {
            presetStore.exportPresetToFile(preset, to: url)
        }
    }

    private func showPresetInFinder(_ preset: Preset) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let presetsDir = appSupport.appendingPathComponent("InputConfig/presets")
        let filePath = presetsDir.appendingPathComponent(preset.filename).path
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
    }

    private func sharePreset(_ preset: Preset) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let presetsDir = appSupport.appendingPathComponent("InputConfig/presets")
        let fileURL = presetsDir.appendingPathComponent(preset.filename)

        let picker = NSSharingServicePicker(items: [fileURL])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            let frame = contentView.bounds
            let rect = NSRect(x: frame.midX, y: frame.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }
}

// MARK: - Controller Chip View

struct ControllerChipView: View {
    let controller: GCController
    let index: Int
    let color: Color
    let info: ControllerInfo?
    let onSetLight: (Float, Float, Float) -> Void
    let onSetBrightness: (UInt8) -> Void
    let onToggleRGB: () -> Void
    let isRGBActive: Bool
    let onRefresh: () -> Void
    /// Jump to the example preset that best matches this controller.
    let onOpenExample: () -> Void
    /// Live binding to the shared RGB cycle speed (the slider in the menu).
    @Binding var rgbSpeed: Double

    @State private var showPopover = false

    // Accurate light bar colors tuned to match actual DualSense LED output
    private static let lightPresets: [(name: String, r: Float, g: Float, b: Float)] = [
        ("Red",    1.0, 0.0, 0.0),
        ("Orange", 1.0, 0.35, 0.0),
        ("Yellow", 1.0, 0.7, 0.0),
        ("Green",  0.0, 1.0, 0.0),
        ("Cyan",   0.0, 1.0, 1.0),
        ("Blue",   0.0, 0.0, 1.0),
        ("Purple", 0.5, 0.0, 1.0),
        ("Pink",   1.0, 0.0, 0.6),
        ("White",  1.0, 1.0, 1.0),
        ("Off",    0.0, 0.0, 0.0),
    ]

    @State private var customColor = Color.blue
    @State private var brightness: Double = 2
    @State private var uptimeTimer: Timer?
    @State private var uptimeText: String = ""

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Controller icon
            ControllerGlyph(height: 11)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(controller.vendorName ?? "Controller \(index)")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let info = info {
                    Text(shortDescription(info))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Battery indicator
            if let info = info, info.hasBattery, let level = info.batteryLevel {
                batteryView(level: level, state: info.batteryState)
            }

            // Light indicator
            if info?.hasLight == true {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow.opacity(0.7))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hoverFill(isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            showPopover.toggle()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(controller.vendorName ?? "Controller \(index)")
        .accessibilityValue(chipAccessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens controller light and settings")
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            controllerPopover
        }
    }

    /// Battery and light status summarized for VoiceOver so the chip reads
    /// its full state without exposing the decorative indicators separately.
    private var chipAccessibilityValue: String {
        var parts: [String] = []
        if let info = info, info.hasBattery, let level = info.batteryLevel {
            parts.append("Battery \(Int(level * 100)) percent")
        }
        if info?.hasLight == true {
            parts.append("Light on")
        }
        return parts.joined(separator: ", ")
    }

    private func shortDescription(_ info: ControllerInfo) -> String {
        var parts: [String] = []
        // Prefer the detected brand name (DualSense, Switch Pro, etc.) when we
        // know it, since it is friendlier than productCategory (which is often
        // just "Extended Gamepad" or similar).
        if info.brand != .unknown && info.brand != .mfiGeneric {
            parts.append(info.brand.displayName)
        } else {
            parts.append(info.productCategory)
        }
        parts.append("\(info.buttonCount) btns")
        parts.append("\(info.axisCount) axes")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func batteryView(level: Float, state: String?) -> some View {
        HStack(spacing: 2) {
            let pct = Int(level * 100)
            let icon: String = {
                if state == "Charging" { return "battery.100percent.bolt" }
                if pct >= 75 { return "battery.100percent" }
                if pct >= 50 { return "battery.75percent" }
                if pct >= 25 { return "battery.50percent" }
                return "battery.25percent"
            }()
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(pct <= 20 ? .red : .secondary)
            Text("\(pct)%")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Popover

    private var controllerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                ControllerGlyph(height: 16)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.vendorName ?? "Controller \(index)")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("Slot \(index)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !uptimeText.isEmpty {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(uptimeText)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
            }

            Divider()

            // Details
            if let info = info {
                detailGrid(info)

                // Every controller - including ones we don't recognize -
                // gets a one-tap jump to the example preset that best fits
                // it (unrecognized pads fall back to the DualSense layout).
                Button {
                    showPopover = false
                    onOpenExample()
                } label: {
                    Label("Take me to an example preset", systemImage: "sparkles")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.solidSecondaryCompact)
                .padding(.top, 2)
            }

            // Light color picker
            if info?.hasLight == true {
                Divider()
                lightColorSection
            }

            // Available buttons
            if let info = info, !info.physicalButtonNames.isEmpty {
                Divider()
                DisclosureGroup {
                    Text(info.physicalButtonNames.joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Raw Buttons (\(info.physicalButtonNames.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
                .focusable(false)
                .focusEffectDisabled()
            }

            Divider()

            Button {
                onRefresh()
                showPopover = false
            } label: {
                Label("Refresh Controllers", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.solidSecondaryCompact)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { startUptimeTimer() }
        .onDisappear { uptimeTimer?.invalidate(); uptimeTimer = nil }
    }

    private func startUptimeTimer() {
        updateUptime()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in updateUptime() }
        }
    }

    private func updateUptime() {
        guard let info = info else { uptimeText = ""; return }
        let elapsed = Int(Date().timeIntervalSince(info.connectedAt))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        if h > 0 {
            uptimeText = String(format: "%d:%02d:%02d connected", h, m, s)
        } else {
            uptimeText = String(format: "%d:%02d connected", m, s)
        }
    }

    @ViewBuilder
    private func detailGrid(_ info: ControllerInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            detailRow("Brand", info.brand.manufacturer)
            detailRow("Type", info.productCategory)
            detailRow("Gamepad", info.hasExtendedGamepad ? "Extended" : "Basic")
            detailRow("Buttons", "\(info.buttonCount)")
            detailRow("Axes", "\(info.axisCount)")
            if info.supportsMotion {
                detailRow("Motion", "Gyro + Accelerometer")
            }
            if info.hasBattery {
                let level = info.batteryLevel.map { "\(Int($0 * 100))%" } ?? "N/A"
                let state = info.batteryState ?? "Unknown"
                detailRow("Battery", "\(level) (\(state))")
            }
            detailRow("Light Bar", info.hasLight ? "Supported" : "None")
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
        }
    }

    private var lightColorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Light Bar Color")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Preset color grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 8) {
                ForEach(Self.lightPresets, id: \.name) { preset in
                    let swatchColor = preset.name == "Off" ? Color.gray.opacity(0.3) :
                        Color(red: Double(preset.r), green: Double(preset.g), blue: Double(preset.b))
                    LightSwatchButton(
                        name: preset.name,
                        color: swatchColor,
                        action: { onSetLight(preset.r, preset.g, preset.b) }
                    )
                }
            }

            Divider()

            // Custom color picker
            HStack(spacing: 10) {
                Text("Custom Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Custom light bar color")

                Button("Apply") {
                    let nsColor = NSColor(customColor).usingColorSpace(.sRGB) ?? NSColor(customColor)
                    let r = Float(nsColor.redComponent)
                    let g = Float(nsColor.greenComponent)
                    let b = Float(nsColor.blueComponent)
                    onSetLight(r, g, b)
                }
                .buttonStyle(.solidCompact)
                .controlSize(.small)
            }

            Divider()

            // Brightness control
            VStack(alignment: .leading, spacing: 4) {
                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: "light.min")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Picker("", selection: $brightness) {
                        Text("Off").tag(0.0)
                        Text("Dim").tag(1.0)
                        Text("Bright").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: brightness) { _, newValue in
                        onSetBrightness(UInt8(newValue))
                    }
                    .accessibilityLabel("Light bar brightness")

                    Image(systemName: "light.max")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // RGB cycle mode
            Button {
                onToggleRGB()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isRGBActive ? "stop.circle.fill" : "rainbow")
                        .foregroundStyle(isRGBActive ? .red : .secondary)
                    Text(isRGBActive ? "Stop RGB Cycle" : "RGB Cycle")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.solidSecondaryCompact)
            .controlSize(.small)
            .tint(isRGBActive ? .red : .accentColor)

            // RGB cycle speed - shared across every RGB menu.
            VStack(alignment: .leading, spacing: 4) {
                Text("Cycle Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "tortoise")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Slider(value: $rgbSpeed, in: 0.25...6.0)
                        .accessibilityLabel("RGB cycle speed")
                        .accessibilityValue(String(format: "%.2f times normal", rgbSpeed))
                    Image(systemName: "hare")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Light Swatch Button

private struct LightSwatchButton: View {
    let name: String
    let color: Color
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Circle()
                    .fill(color)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(isHovering ? 0.4 : 0.12), lineWidth: isHovering ? 1.5 : 0.5)
                    )
                    .frame(width: 24, height: 24)
                    .shadow(color: color.opacity(isHovering ? 0.6 : 0.3), radius: isHovering ? 4 : 2)
                    .scaleEffect(!reduceMotion && isHovering ? 1.15 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: isHovering)
                Text(name)
                    .font(.system(size: 8))
                    .foregroundStyle(isHovering ? .secondary : .tertiary)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Preset Row View

struct PresetRowView: View {
    let preset: Preset
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onShowInFinder: () -> Void
    let onShare: () -> Void
    let onImport: () -> Void
    let onDelete: () -> Void
    let onConvert: (ControllerType, ControllerType) -> Void

    /// Toggled when the user clicks the trailing ellipsis next to a
    /// truncated description. Collapses back when toggled off, the row is
    /// deselected, or another row is selected.
    @State private var descriptionExpanded: Bool = false

    /// Active state is normally conveyed only by the green row tint;
    /// with Differentiate Without Color on we add a glyph as well.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Whether the row should offer an expand toggle. We err on the side
    /// of showing it: any non-trivial tag (>= 16 chars, since sidebar
    /// width often clips around there) OR any notes content qualifies.
    /// 16 instead of 40 means narrow-sidebar users actually get the
    /// button when their text is in fact truncated.
    private var descriptionTruncates: Bool {
        preset.tag.count >= 16 || !preset.notes.isEmpty
    }

    var body: some View {
        // Single-line row: name on top, optional chevron beside the
        // truncated tag. Clicking the chevron pops up the full
        // description as a popover floating below the row. We use a
        // popover instead of inline expansion because List(.sidebar)
        // enforces a fixed row height that silently clips any
        // multi-line text - the popover floats outside the row
        // entirely and is guaranteed to show the full text.
        mainRow
    }

    /// Top half of the row: name, single-line description with the trailing
    /// ellipsis-toggle, then the trailing options Menu. Always the same
    /// height regardless of expansion.
    @ViewBuilder
    private var mainRow: some View {
        HStack(spacing: 6) {
            if preset.isActive && differentiateWithoutColor {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .iconTint(.green)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.body)
                    .lineLimit(1)

                // Single-line tag preview. The truncation toggle that
                // used to sit inline next to the tag now lives outside
                // the VStack so it aligns at a consistent x position
                // across all rows, right next to the options menu.
                Text(preset.tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(preset.isActive ? "Active" : "Inactive")
            .accessibilityAddTraits(preset.isActive ? [.isSelected] : [])

            Spacer(minLength: 4)

            // Description-expand chevron, pinned to the row's right
            // side so every row's chevron lines up vertically. Same
            // 18pt slot whether or not the chevron is showing, so the
            // ellipsis below doesn't shift between truncated and
            // untruncated rows.
            ZStack {
                if descriptionTruncates {
                    Button {
                        descriptionExpanded.toggle()
                    } label: {
                        Image(systemName: descriptionExpanded
                              ? "chevron.up"
                              : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(descriptionExpanded
                          ? "Collapse description"
                          : "Show full description")
                    .accessibilityLabel(descriptionExpanded
                                        ? "Collapse description"
                                        : "Show full description")
                    .popover(isPresented: $descriptionExpanded,
                             arrowEdge: .bottom) {
                        descriptionPopover
                    }
                }
            }
            .frame(width: 18, alignment: .center)

            // Options menu
            Menu {
                Button(preset.isActive ? "Deactivate" : "Activate") {
                    onActivate()
                }

                Button("Edit") {
                    onEdit()
                }

                Button("Duplicate") {
                    onDuplicate()
                }

                Divider()

                Menu("Convert To...") {
                    ForEach(ControllerType.allCases) { sourceType in
                        Menu("From \(sourceType.rawValue)") {
                            ForEach(ControllerType.allCases.filter { $0 != sourceType }) { destType in
                                Button("To \(destType.rawValue)") {
                                    onConvert(sourceType, destType)
                                }
                            }
                        }
                    }
                }

                Button("Export...") {
                    onExport()
                }

                Button("Import Preset File...") {
                    onImport()
                }

                Divider()

                Button("Show in Finder") {
                    onShowInFinder()
                }

                Button("Share...") {
                    onShare()
                }

                Divider()

                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundColor(Color.gray.opacity(0.55))
                    .frame(width: 16, height: 22, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 16, alignment: .trailing)
            .accessibilityLabel("\(preset.name) options")
            .accessibilityHint("Activate, edit, duplicate, convert, share, or delete this preset")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(preset.isActive ? "Deactivate" : "Activate") {
                onActivate()
            }

            Button("Edit") {
                onEdit()
            }

            Button("Duplicate") {
                onDuplicate()
            }

            Divider()

            Menu("Convert To...") {
                ForEach(ControllerType.allCases) { sourceType in
                    Menu("From \(sourceType.rawValue)") {
                        ForEach(ControllerType.allCases.filter { $0 != sourceType }) { destType in
                            Button("To \(destType.rawValue)") {
                                onConvert(sourceType, destType)
                            }
                        }
                    }
                }
            }

            Button("Export...") { onExport() }
            Button("Import Preset File...") { onImport() }

            Divider()

            Button("Show in Finder") { onShowInFinder() }
            Button("Share...") { onShare() }

            Divider()

            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    /// Floating popover anchored to the chevron button. Renders OUTSIDE
    /// the List row container so the sidebar's fixed-row-height
    /// enforcement can't clip multi-line text. The popover has its
    /// own fixed width (280pt) and grows vertically with the content.
    @ViewBuilder
    private var descriptionPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preset.name)
                .font(.headline)
            if !preset.tag.isEmpty {
                Text(preset.tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !preset.notes.isEmpty {
                Divider()
                Text("Notes")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(preset.notes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - Preset Detail View

struct PresetDetailView: View {
    @SwiftUI.Binding var preset: Preset
    let onEdit: () -> Void
    let onToggle: () -> Void
    /// Asks ContentView to open the editor scrolled to a specific binding
    /// row. Forwarded down to VirtualControllerView, which fires this when
    /// the user taps a row inside any widget popover.
    var onJumpToBinding: (EditorJumpTarget) -> Void = { _ in }

    // PresetDetailView does not read the mapping engine directly (the
    // visualizer it embeds gets the engine from a higher injection), so it
    // must NOT subscribe to it here: doing so rebuilt this whole detail body
    // at the engine's 10-30 Hz publish rate while a preset was active.
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var presetStore: PresetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { detailProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Anchor for the Quick Tour's scroll-to-top.
                    Color.clear.frame(height: 0).id("detail-top")

                    // 1. Header (name, tag, Activate, Edit).
                    headerSection
                        .padding(.horizontal)
                        .padding(.top, 8)

                    // 2. Live Visualizer card.
                    // Tagged so the tour can scrollTo("visualizer-section")
                    // without having to fish through nested SwiftUI views.
                    Color.clear.frame(height: 0).id("visualizer-section")
                    visualizerCard
                        .padding(.horizontal)
                        .spotlightAnchor(SpotlightID.visualizer)

                    // 2b. Light Bar card: per-preset controller light color,
                    //     promoted out of the visualizer so it's findable.
                    if hasLightCapableController {
                        sectionCard { presetLightBarSection }
                            .padding(.horizontal)
                    }

                    // 3. Joystick Slots card (mapping count + comment per
                    //    joystick group in the preset).
                    if !preset.joysticks.isEmpty {
                        joystickSlotsCard
                            .padding(.horizontal)
                    } else {
                        ContentUnavailableView {
                            Label { Text("No Joystick Mappings") } icon: { ControllerGlyph(height: 22) }
                        } description: {
                            Text("Edit this preset to add joystick mappings.")
                        }
                    }

                    // 4. Notes card. Personal context (which game, gotchas)
                    //    belongs right after the mappings, before the
                    //    technical file metadata below.
                    notesCard
                        .padding(.horizontal)
                        .spotlightAnchor(SpotlightID.notesSection)

                    // 5. Details card (Usage, Inputs, Outputs, Controllers,
                    //    Storage, version history).
                    detailsCard
                        .padding(.horizontal)
                }
                .padding(.vertical, 14)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToVisualizer)) { _ in
                showVisualizer = true
                withAnimation(.easeOut(duration: 0.45)) {
                    detailProxy.scrollTo("visualizer-section", anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .inputConfigScrollToTop)) { _ in
                withAnimation(.easeOut(duration: 0.45)) {
                    detailProxy.scrollTo("detail-top", anchor: .top)
                }
            }
            } // ScrollViewReader

        }
        .navigationTitle(preset.name)
        .sheet(isPresented: $showingTouchpadCalFromDetail) {
            TouchpadCalibrationView()
                .environmentObject(presetStore)
                .glassBackground()
        }
        .sheet(isPresented: $showingMotionCalFromDetail) {
            MotionCalibrationView()
                .environmentObject(controllerService)
                .glassBackground()
        }
    }

    // MARK: - Section card helpers

    /// Wraps a section in a uniform Liquid Glass card. Used by every major
    /// section of the detail panel so they read as one related set and carry
    /// the same real glass as the rest of the app family (spec section 2).
    @ViewBuilder
    private func sectionCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            content()
        }
        .padding(Metrics.cardPad)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }

    /// Standard header row for a section card: tinted SF Symbol, title,
    /// optional trailing content (e.g. a chevron or status pill).
    @ViewBuilder
    private func sectionHeader<Trailing: View>(
        icon: String,
        title: String,
        tint: Color = .secondary,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            IconView(name: icon, glyphHeight: 12)
                .iconTint(tint)
                .font(.subheadline)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            trailing()
        }
    }

    // MARK: - Section: Header

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Preset Name", text: $preset.name)
                    .font(.title2)
                    .fontWeight(.regular)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                TextField("Tag / Description", text: $preset.tag)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    Label(
                        preset.isActive ? "Deactivate" : "Activate",
                        systemImage: preset.isActive ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(SolidButton(tint: preset.isActive ? .red : .green))
                .spotlightAnchor(SpotlightID.activateButton)
                .accessibilityLabel(preset.isActive
                                    ? "Deactivate \(preset.name)"
                                    : "Activate \(preset.name)")
                .accessibilityHint(preset.isActive
                                   ? "Stops the mapping engine for this preset"
                                   : "Starts the mapping engine and applies this preset")

                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.solidSecondary)
                .spotlightAnchor(SpotlightID.editButton)
                .accessibilityLabel("Edit bindings and mappings")
                .accessibilityHint("Opens the binding editor for this preset")
            }
        }
        .spotlightAnchor(SpotlightID.detailHeader)
    }

    // MARK: - Section: Live Visualizer card

    @ViewBuilder
    private var visualizerCard: some View {
        sectionCard {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showVisualizer.toggle() }
            } label: {
                sectionHeader(icon: "gamecontroller", title: "Live Visualizer",
                              tint: .teal) {
                    Image(systemName: showVisualizer ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showVisualizer
                                ? "Collapse Live Visualizer"
                                : "Expand Live Visualizer")

            if showVisualizer {
                visualizerContent
            }
        }
    }

    /// The visualizer body extracted so it can be embedded directly in a
    /// section card (with our own collapse chevron) instead of a
    /// Stable identity for each visualizer row so a VirtualControllerView's
    /// @State (gyro integrator, etc.) tracks its controller, not its position.
    /// Keying the ForEach by array index let that state bleed onto a different
    /// controller when one connected or disconnected and shifted the slots.
    private struct VisualizerSlot: Identifiable {
        let id: String
        let idx: Int
        let slot: Int
    }

    /// DisclosureGroup whose chevron sat awkwardly next to the card.
    @ViewBuilder
    private var visualizerContent: some View {
        let connectedSlots = Array(controllerService.controllerDetails.keys).sorted()
        let presetJoystickCount = preset.joysticks.count
        let totalVisualizers = max(presetJoystickCount, connectedSlots.count)
        let resolvedVisualizerSlots: [VisualizerSlot] = (0..<totalVisualizers).map { idx in
            let connected = idx < connectedSlots.count
            let slot = connected ? connectedSlots[idx] : idx
            return VisualizerSlot(id: connected ? "slot-\(slot)" : "empty-\(idx)", idx: idx, slot: slot)
        }
        if connectedSlots.isEmpty && presetJoystickCount == 0 {
            Text("Connect a controller to see its live state here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(resolvedVisualizerSlots) { viz in
                    let idx = viz.idx
                    let slot = viz.slot
                    HStack(spacing: 8) {
                        Text("Joystick #\(idx)")
                            .font(.caption2.weight(.semibold).monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.12))
                            )
                        Spacer()
                    }
                    VirtualControllerView(
                        preset: preset,
                        onJump: { target in
                            onJumpToBinding(target)
                        },
                        fixedSlot: slot,
                        // The light bar controls used to ride along here as a
                        // trailing pane; they now live in their own Light Bar
                        // card below the visualizer where they're findable.
                        trailing: {},
                        lightBarTint: presetLightBarSwiftUIColor,
                        onChangeInputKind: { changedSlot, newKind in
                            updateSlotInputKind(
                                presetID: preset.id,
                                slot: changedSlot,
                                kind: newKind)
                        }
                    )
                    .environmentObject(controllerService)
                }
            }
        }
    }

    // MARK: - Section: Joystick Slots card

    /// Compact summary of every joystick mapping in the preset, grouped
    /// into a single card instead of the loose stack of mini cards we
    /// used to render under the visualizer.
    @ViewBuilder
    private var joystickSlotsCard: some View {
        sectionCard {
            sectionHeader(icon: "rectangle.stack.fill",
                          title: "Joystick Slots",
                          tint: .indigo) {
                // Calibration shortcuts, so hardware tuning is reachable
                // right from the detail view instead of only inside the
                // editor's toolbar.
                if hasTouchpadCapableController || hasMotionCapableController {
                    Menu {
                        if hasTouchpadCapableController {
                            Button("Calibrate Touchpad...") { showingTouchpadCalFromDetail = true }
                        }
                        if hasMotionCapableController {
                            Button("Calibrate Motion...") { showingMotionCalFromDetail = true }
                        }
                    } label: {
                        Label("Calibrate", systemImage: "scope")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Calibrate")
                    .accessibilityHint("Opens touchpad or motion calibration for the connected controller.")
                }
                Text("\(preset.joysticks.count) \(preset.joysticks.count == 1 ? "slot" : "slots")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 6) {
                ForEach(Array(preset.joysticks.enumerated()), id: \.element.id) { index, joystick in
                    joystickSlotRow(index: index, joystick: joystick)
                }
            }
        }
    }

    @ViewBuilder
    private func joystickSlotRow(index: Int, joystick: JoystickMapping) -> some View {
        let bindingCount = joystick.bindings.count
        let hasComment = !joystick.tag.isEmpty && joystick.tag != "<write comments here>"

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(resolvedJoystickName(joystick: joystick, slot: index))
                    .font(.subheadline)
                if joystick.customName == nil {
                    Text("#\(index)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(bindingCount) \(bindingCount == 1 ? "binding" : "bindings")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if hasComment {
                Text(joystick.tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Section: Details card

    @ViewBuilder
    private var detailsCard: some View {
        sectionCard {
            sectionHeader(icon: "info.circle.fill",
                          title: "Details",
                          tint: .blue)
            detailsSection
        }
    }

    // MARK: - Section: Notes card

    /// Notes section card. The internal `presetNotesSection` still
    /// renders the icon, label, and TextEditor; the surrounding
    /// sectionCard provides the consistent frame.
    @ViewBuilder
    private var notesCard: some View {
        sectionCard {
            presetNotesSection
        }
    }

    /// Resolve the display name for a joystick mapping slot. Priority:
    ///   1. The user's `customName` if they renamed it.
    ///   2. The currently-connected controller's product name for that
    ///      slot (e.g. "DualSense Wireless Controller").
    ///   3. The fallback "Joystick #N".
    private func resolvedJoystickName(joystick: JoystickMapping, slot: Int) -> String {
        if let custom = joystick.customName, !custom.isEmpty {
            return custom
        }
        if let info = controllerService.controllerDetails[slot] {
            let trimmed = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Joystick #\(slot)"
    }

    /// Apply the visualizer picker's choice back to the preset model
    /// and persist via the store. Auto-creates the joystick mapping
    /// for the slot if one doesn't exist yet (so the picker works on
    /// brand-new presets with no joysticks defined).
    fileprivate func updateSlotInputKind(presetID: UUID, slot: Int, kind: SlotInputKind) {
        guard preset.id == presetID else { return }
        var updated = preset
        while updated.joysticks.count <= slot {
            updated.joysticks.append(JoystickMapping(tag: ""))
        }
        updated.joysticks[slot].inputKind = kind
        updated.modifiedAt = Date()
        preset = updated
        presetStore.savePreset(updated)
    }

    // MARK: - Details

    /// Two-column metadata grid. Left column: Usage / Inputs / Outputs (what
    /// the preset asks for). Right column: Controllers / Storage (what the
    /// user's hardware + filesystem state look like). Saves vertical
    /// space versus the old stacked layout while keeping every datum.
    @ViewBuilder
    private var detailsSection: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                detailsRow(title: "Usage", icon: "list.bullet.rectangle",
                           items: usageBullets)
                detailsRow(title: "Inputs", icon: "gamecontroller",
                           items: inputBullets)
                detailsRow(title: "Outputs", icon: "arrow.right.circle",
                           items: outputBullets)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                if controllerService.connectedControllers.isEmpty
                    && controllerService.rawHIDGamepadSlots.isEmpty {
                    detailsRow(title: "Controllers", icon: "antenna.radiowaves.left.and.right.slash",
                               items: ["No controllers currently connected."])
                } else {
                    detailsRow(title: "Controllers", icon: "antenna.radiowaves.left.and.right",
                               items: controllerBullets)
                }
                storageRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Storage section with Finder + version-history actions instead of a
    /// plain bullet list.
    @ViewBuilder
    private var storageRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc")
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Storage")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(preset.filename)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        revealInFinder()
                    } label: {
                        Label("Open in Finder", systemImage: "arrow.up.right.square")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text("Modified \(modifiedRelative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                versionsDisclosure
            }
            Spacer(minLength: 0)
        }
    }

    @State private var showVersions: Bool = false
    @State private var showVisualizer: Bool = true
    /// Focus state for the notes editor, so the placeholder hides as soon as
    /// the field is clicked rather than waiting for the first typed character.
    @FocusState private var notesFocused: Bool
    /// Calibration sheets launched from the Joystick Slots card header.
    @State private var showingTouchpadCalFromDetail = false
    @State private var showingMotionCalFromDetail = false

    /// True when any connected controller has a touchpad / motion sensors.
    /// Drives the Calibrate shortcut menu's visibility and contents.
    private var hasTouchpadCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.hasTouchpad }
    }
    private var hasMotionCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.supportsMotion }
    }
    /// Cached snapshot of the preset's version history. Loaded once per
    /// preset change instead of every render - the disk read + JSON decode
    /// inside `versions(for:)` is expensive enough that calling it on the
    /// SwiftUI render hot path was pegging the CPU once a controller was
    /// connected (each input poll triggered another full reload).
    @State private var cachedVersions: [PresetStore.PresetVersion] = []

    @ViewBuilder
    private var versionsDisclosure: some View {
        Group {
            if cachedVersions.isEmpty {
                HStack(spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text("No previous versions yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                DisclosureGroup(isExpanded: $showVersions) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cachedVersions) { version in
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(versionLabel(version))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button("Revert") {
                                    revertToVersion(version)
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        Text("Previous versions (\(cachedVersions.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            }
        }
        .onAppear { reloadVersions() }
        .onChange(of: preset.id) { _, _ in reloadVersions() }
        // Intentionally NOT keyed on preset.modifiedAt: that fired a synchronous
        // versions(for:) disk read on EVERY keystroke while editing the name,
        // tag, or notes. The list reloads on preset switch and on appear, which
        // is when this collapsed "Previous versions" group is actually viewed.
    }

    private func reloadVersions() {
        cachedVersions = presetStore.versions(for: preset)
    }

    // MARK: - Per-preset Notes

    @ViewBuilder
    private var presetNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .iconTint(.yellow)
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !preset.notes.isEmpty {
                    Text("\(preset.notes.count) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            // Plain TextEditor so users can paste multi-line context (which
            // controller this preset is for, what game, gotchas, etc.).
            // Persisted via the same `savePreset` path that the rest of the
            // detail page already uses on change.
            TextEditor(text: $preset.notes)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .focused($notesFocused)
                .frame(minHeight: 60, maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                )
                .overlay(alignment: .topLeading) {
                    if preset.notes.isEmpty && !notesFocused {
                        Text("Start typing...")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Per-preset Light Bar override

    /// SwiftUI Color for the preset's light-bar override, if any. nil
    /// when no override is set - the visualizer's strip widget uses this
    /// to render its current state.
    private var presetLightBarSwiftUIColor: Color? {
        guard let rgb = preset.lightBarColor else { return nil }
        return Color(red: Double(rgb.floatR),
                     green: Double(rgb.floatG),
                     blue: Double(rgb.floatB))
    }

    /// Brightness override binding. Bridges the optional `Int?` in the model
    /// to a non-optional `Double` for the segmented picker. nil maps to 2
    /// (bright) which is the slot default.
    private var presetBrightnessBinding: SwiftUI.Binding<Double> {
        SwiftUI.Binding(
            get: { Double(preset.lightBarBrightness ?? 2) },
            set: { preset.lightBarBrightness = Int($0) }
        )
    }

    /// Color binding that round-trips between SwiftUI Color and the
    /// model's RGBLightColor (UInt8 components). Defaults to slot blue when
    /// the preset hasn't picked an override yet.
    private var presetColorBinding: SwiftUI.Binding<Color> {
        SwiftUI.Binding(
            get: {
                if let rgb = preset.lightBarColor {
                    return Color(red: Double(rgb.floatR),
                                 green: Double(rgb.floatG),
                                 blue: Double(rgb.floatB))
                }
                return .blue
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                preset.lightBarColor = RGBLightColor(
                    floatR: Float(ns.redComponent),
                    floatG: Float(ns.greenComponent),
                    floatB: Float(ns.blueComponent)
                )
            }
        )
    }

    @ViewBuilder
    private var presetLightBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "light.beacon.max.fill")
                    .foregroundStyle(.pink)
                Text("Light Bar for this preset")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if preset.lightBarColor != nil {
                    Button {
                        preset.lightBarColor = nil
                        preset.lightBarBrightness = nil
                    } label: {
                        Label("Clear override", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .controlSize(.small)
                    .help("Forget this preset's color and use the controller's general light instead")
                }
            }

            Text(preset.lightBarColor == nil
                 ? "No override set. The controller will keep its general color while this preset is active."
                 : "When this preset activates, the controller's light bar switches to this color. Deactivating reverts to the general color.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Visible warning so users don't think the color preview is
            // broken when nothing changes on the physical light bar until
            // the preset is activated.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption2)
                Text("Color only takes effect on the controller while this preset is activated. Hit Activate above to test it live.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )

            // Swatches grid - wraps to a second row in the narrow popover.
            // LazyVGrid with adaptive columns lets the swatches reflow when
            // the popover gets resized.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(lightBarPresets, id: \.name) { swatch in
                    Button {
                        presetColorBinding.wrappedValue = swatch.color
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }
            }

            // Custom color + brightness, each on their own row so the
            // labels can't get squeezed to vertical in a narrow popover.
            HStack(spacing: 8) {
                Text("Custom color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                ColorPicker("", selection: presetColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: presetBrightnessBinding) {
                    Text("Off").tag(0.0)
                    Text("Dim").tag(1.0)
                    Text("Bright").tag(2.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func versionLabel(_ v: PresetStore.PresetVersion) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let bindings = v.preset.joysticks.flatMap(\.bindings).count
        return "\(formatter.string(from: v.savedAt))  •  \(bindings) binding\(bindings == 1 ? "" : "s")"
    }

    private func revertToVersion(_ v: PresetStore.PresetVersion) {
        presetStore.revertPreset(preset, to: v)
    }

    private func revealInFinder() {
        let url = presetStore.fileURL(for: preset)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @ViewBuilder
    private func detailsRow(title: String, icon: String, items: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconView(name: icon, glyphHeight: 11)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Detail bullet computation

    private var allBindings: [BindingModel] {
        preset.joysticks.flatMap(\.bindings)
    }

    private var usageBullets: [String] {
        // Tag already lives in the editable subtitle at the top - don't
        // restate it here.
        var bullets: [String] = []
        bullets.append("\(preset.joysticks.count) joystick mapping" +
                       (preset.joysticks.count == 1 ? "" : "s"))
        bullets.append("\(allBindings.count) total binding" +
                       (allBindings.count == 1 ? "" : "s"))
        return bullets
    }

    private var inputBullets: [String] {
        var counts: [InputType: Int] = [:]
        for b in allBindings { counts[b.input.type, default: 0] += 1 }
        var bullets: [String] = []
        if let n = counts[.button], n > 0 { bullets.append("Buttons: \(n) binding\(n == 1 ? "" : "s")") }
        if let n = counts[.axis], n > 0 { bullets.append("Axes: \(n) binding\(n == 1 ? "" : "s")") }
        if let n = counts[.hat], n > 0 { bullets.append("Hat (D-pad): \(n) binding\(n == 1 ? "" : "s")") }
        if let n = counts[.touchpad], n > 0 {
            bullets.append("Touchpad surface: \(n) binding\(n == 1 ? "" : "s") (DualSense / DualShock 4 only)")
        }
        if let n = counts[.touchpadRegion], n > 0 {
            bullets.append("Touchpad regions: \(n) tap binding\(n == 1 ? "" : "s")")
        }
        if bullets.isEmpty { bullets.append("No inputs bound yet.") }
        return bullets
    }

    private var outputBullets: [String] {
        var types: Set<OutputType> = []
        var haptic = 0
        var speech = 0
        var macro = 0
        var turbo = 0
        for b in allBindings {
            for o in b.outputs { types.insert(o.type) }
            if b.hapticEnabled == true { haptic += 1 }
            if b.speechEnabled == true { speech += 1 }
            if b.macroSteps?.isEmpty == false { macro += 1 }
            if b.turboEnabled == true { turbo += 1 }
        }
        var bullets: [String] = []
        if types.contains(.key) { bullets.append("Keyboard keystrokes") }
        if types.contains(.mouseButton) { bullets.append("Mouse buttons") }
        if types.contains(.mouseMotion) { bullets.append("Mouse motion") }
        if types.contains(.mouseWheel) || types.contains(.mouseWheelStep) { bullets.append("Scroll wheel") }
        if types.contains(.midiNote) || types.contains(.midiCC)
            || types.contains(.midiPitchBend) || types.contains(.midiProgramChange)
            || types.contains(.midiTransport) {
            bullets.append("MIDI (CoreMIDI virtual source)")
        }
        if haptic > 0 { bullets.append("Haptic feedback on \(haptic) binding\(haptic == 1 ? "" : "s")") }
        if speech > 0 { bullets.append("Spoken feedback on \(speech) binding\(speech == 1 ? "" : "s")") }
        if macro > 0 { bullets.append("Macros: \(macro)") }
        if turbo > 0 { bullets.append("Turbo: \(turbo)") }
        if bullets.isEmpty { bullets.append("No outputs configured.") }
        return bullets
    }

    private var controllerBullets: [String] {
        // Battery percentage and similar live state already shows in the
        // sidebar's controller status bar - we don't restate it here. This
        // section focuses on whether the connected hardware can run the
        // preset (button counts, special features, profile match).
        var bullets: [String] = []
        let sortedIndices = controllerService.controllerDetails.keys.sorted()
        for idx in sortedIndices {
            guard let info = controllerService.controllerDetails[idx] else { continue }
            var line = info.name
            if info.brand != .unknown {
                line += "  •  \(info.brand.displayName)"
            }
            bullets.append(line)
            var caps: [String] = []
            caps.append("\(info.buttonCount) buttons")
            caps.append("\(info.axisCount) axes")
            if info.hasTouchpad { caps.append("touchpad") }
            if info.hasLight { caps.append("light bar") }
            if info.hasAdaptiveTriggers { caps.append("adaptive triggers") }
            if info.supportsMotion { caps.append("motion sensors") }
            bullets.append("Capabilities: \(caps.joined(separator: ", "))")
            bullets.append("Profile: \(info.productCategory)" +
                           (info.hasExtendedGamepad ? "  •  extended MFi" : ""))
        }
        return bullets
    }

    private var modifiedRelative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: preset.modifiedAt, relativeTo: Date())
    }

    // MARK: - Light Bar

    private var hasLightCapableController: Bool {
        controllerService.controllerDetails.values.contains { $0.hasLight }
    }

    private var lightBarPresets: [(name: String, color: Color)] {
        [
            ("Red", .red), ("Orange", .orange), ("Yellow", .yellow),
            ("Green", .green), ("Cyan", .cyan), ("Blue", .blue),
            ("Purple", .purple), ("Pink", .pink), ("White", .white)
        ]
    }
}

/// Compact capability-chip row that wraps to the next line when the
/// containing width runs out. Used by the controller status popover so the
/// chips never overlap or push other elements out of the popover.
struct FlowChipRow: View {
    let chips: [(String, Color)]

    var body: some View {
        if chips.isEmpty {
            EmptyView()
        } else {
            // Use SwiftUI's built-in flow layout (macOS 13+) - wraps chips
            // to multiple lines when they don't fit.
            FlowLayoutWrapper {
                ForEach(0..<chips.count, id: \.self) { i in
                    Text(chips[i].0)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(chips[i].1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(chips[i].1.opacity(0.15)))
                }
            }
        }
    }
}

/// Tiny flow-wrap container. We can't use SwiftUI 16+ `Layout` because the
/// app deploys to macOS 14, so this falls back to a stacked HStack + the
/// `_VariadicView` mechanism. For simplicity here we use a horizontal
/// wrap via `HStack` + `Spacer` controlled `FlexibleView`-style helper:
/// rendering one HStack per row, breaking on overflow. Implemented with
/// `GeometryReader` measurement.
fileprivate struct FlowLayoutWrapper<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // The simplest workable wrap on macOS 14: a `WrappingHStack`
        // implemented via a `Layout` that arranges proposed sizes left to
        // right and breaks lines. macOS 14 *does* support `Layout`, so we
        // use it here without needing a deployment-target bump.
        WrappingHStackLayout(spacing: 4, lineSpacing: 4) {
            content
        }
    }
}

/// Left-to-right wrapping layout (the macOS equivalent of HTML's
/// inline-block + word-wrap). Each subview is given its ideal size; rows
/// break when the next subview would overflow.
fileprivate struct WrappingHStackLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxXSeen: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxXSeen = max(maxXSeen, x)
            rowHeight = max(rowHeight, size.height)
        }
        let totalHeight = y + rowHeight
        return CGSize(width: min(maxWidth, maxXSeen), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// The in-app "Update available" alert and its UpdateCheckService were
// removed: the Mac App Store delivers update notifications itself, and
// App Review guideline 2.4.5(vii) prohibits in-app update checks.

// MARK: - Smart Preset Maker (guided wizard)

/// Branching wizard that turns a few answers ("Play a game" -> "Roblox" ->
/// "Switch Pro") into a tailored preset, fusing a researched mapping profile
/// with the user's controller and chosen options. Generated presets carry
/// controller-aware setup notes and land in the sidebar where the user picks.
struct SmartPresetMakerView: View {
    @EnvironmentObject var presetStore: PresetStore
    @EnvironmentObject var controllerService: GameControllerService
    @Environment(\.dismiss) private var dismiss
    var onCreated: (Preset) -> Void

    enum Step: Int, CaseIterable { case category, item, controller, options, finish }

    @State private var step: Step = .category
    @State private var category: SmartPresetProfile.Category?
    @State private var profile: SmartPresetProfile?
    @State private var brand: ControllerBrand = .dualSense
    @State private var search = ""

    @State private var autoLaunch = false
    @State private var appPath = ""
    @State private var confine = false
    @State private var recenter = false
    @State private var hideCursor = false
    @State private var lightColor: Color = .green

    @State private var name = ""
    @State private var groupID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            footer
        }
        .frame(width: 580, height: 600)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .iconTint(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Preset Maker").font(.headline)
                Text(stepSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel("Close")
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .category:   categoryStep
        case .item:       itemStep
        case .controller: controllerStep
        case .options:    optionsStep
        case .finish:     finishStep
        }
    }

    private var footer: some View {
        HStack {
            if step != .category {
                Button("Back") { back() }.buttonStyle(.solidSecondary)
            }
            Spacer()
            if step == .options {
                Button("Next") { step = .finish }.buttonStyle(.solid)
            } else if step == .finish {
                Button("Create Preset") { create() }
                    .buttonStyle(.solid)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: Steps

    private var categoryStep: some View {
        VStack(spacing: 12) {
            Text("What do you want to do?").font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(SmartPresetProfile.Category.allCases) { cat in
                Button {
                    category = cat; search = ""; step = .item
                } label: {
                    HStack(spacing: 12) {
                        IconView(name: cat.systemImage, glyphHeight: 17).font(.title2).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(catTitle(cat)).font(.headline)
                            Text(catDesc(cat)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var itemStep: some View {
        let items = (category.map { SmartPresetLibrary.profiles(in: $0) } ?? [])
            .filter {
                search.isEmpty
                || $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.subtitle.localizedCaseInsensitiveContains(search)
            }
        return VStack(alignment: .leading, spacing: 10) {
            Text(category?.pluralPrompt ?? "Pick one").font(.title3.weight(.semibold))
            TextField("Search…", text: $search).textFieldStyle(.roundedBorder)
            if items.isEmpty {
                Text("No matches yet. More titles are added over time.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            ForEach(items) { p in
                Button { select(p) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.displayName).font(.body.weight(.medium))
                            Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var controllerStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which controller?").font(.title3.weight(.semibold))
            ForEach(controllerChoices, id: \.self) { b in
                Button {
                    brand = b
                    if let p = profile { name = "\(p.displayName) (\(b.displayName))" }
                    step = .options
                } label: {
                    HStack(spacing: 10) {
                        ControllerGlyph(height: 15).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(b.displayName)
                                if connectedBrands.contains(b) {
                                    Text("Connected").font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.green.opacity(0.2)))
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(b.capabilitySummary)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var optionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fine-tune").font(.title3.weight(.semibold))
            Toggle("Open the app automatically when this preset activates", isOn: $autoLaunch)
            if autoLaunch {
                HStack {
                    Text(appPath.isEmpty ? "No app chosen" : appPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose App…") { chooseApp() }.buttonStyle(.solidSecondaryCompact)
                }
            }
            Divider()
            Toggle("Confine the mouse to the screen (boundaries)", isOn: $confine)
            Toggle("Auto-recenter the cursor", isOn: $recenter)
            Toggle("Hide the cursor while active", isOn: $hideCursor)
            if brand.hasLightBar {
                Divider()
                HStack {
                    Text("Light bar color")
                    Spacer()
                    ColorPicker("", selection: $lightColor, supportsOpacity: false).labelsHidden()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label { Text("\(brand.displayName) supports: \(brand.capabilitySummary)") } icon: { ControllerGlyph(height: 10) }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if brand.hasMotion {
                    Text("Gyro aim is available - after creating, run Help → Calibrate Motion / Gyro and add a gyro binding.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if brand.hasTouchpad {
                    Text("The touchpad can act as a trackpad - add a Touchpad binding to use it.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let p = profile, !p.tips.isEmpty {
                Divider()
                Text("Tips").font(.caption.weight(.semibold))
                ForEach(p.tips, id: \.self) { tip in
                    Text("• \(tip)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name & save").font(.title3.weight(.semibold))
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Add to folder", selection: $groupID) {
                Text("Ungrouped").tag(UUID?.none)
                ForEach(presetStore.groups) { g in
                    Text(g.name).tag(UUID?.some(g.id))
                }
            }
            if let p = profile {
                VStack(alignment: .leading, spacing: 4) {
                    summaryRow("What", p.displayName)
                    summaryRow("Controller", brand.displayName)
                    summaryRow("Auto-launch", autoLaunch ? "Yes" : "No")
                    summaryRow("Mouse confine", confine ? "On" : "Off")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
            if let p = profile {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mapping preview").font(.caption.weight(.semibold))
                    ForEach(Array(p.bindings.prefix(6).enumerated()), id: \.offset) { _, b in
                        Text("\(SmartPresetGenerator.label(for: b.input, brand: brand))  →  \(b.note)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if p.bindings.count > 6 {
                        Text("+ \(p.bindings.count - 6) more bindings")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))
            }
            Text("After it's created you can edit any binding. If a control doesn't respond, open the binding editor and tap Scan - controllers vary, so the preset notes list what each control should do.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private func back() {
        step = Step(rawValue: max(0, step.rawValue - 1)) ?? .category
    }

    private func select(_ p: SmartPresetProfile) {
        profile = p
        confine = p.confineCursor
        recenter = p.autoRecenter
        hideCursor = p.hideCursor
        autoLaunch = !p.appPath.isEmpty
        appPath = p.appPath
        lightColor = Color(.sRGB,
                           red: Double(p.light.r) / 255.0,
                           green: Double(p.light.g) / 255.0,
                           blue: Double(p.light.b) / 255.0)
        if let connected = connectedBrands.first { brand = connected }
        name = "\(p.displayName) (\(brand.displayName))"
        step = .controller
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["app"]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { appPath = url.path }
    }

    private func create() {
        guard let p = profile else { return }
        let ns = NSColor(lightColor).usingColorSpace(.sRGB) ?? NSColor(lightColor)
        let lc = SmartPresetProfile.Light(
            r: Int((ns.redComponent * 255).rounded()),
            g: Int((ns.greenComponent * 255).rounded()),
            b: Int((ns.blueComponent * 255).rounded()))
        let opts = SmartPresetGenerator.Options(
            name: name.trimmingCharacters(in: .whitespaces),
            groupID: groupID,
            autoLaunchApp: autoLaunch,
            appPathOverride: appPath.isEmpty ? nil : appPath,
            confineCursor: confine,
            autoRecenter: recenter,
            hideCursor: hideCursor,
            lightColor: lc)
        let preset = SmartPresetGenerator.makePreset(from: p, brand: brand, options: opts)
        presetStore.savePreset(preset)
        onCreated(preset)
        dismiss()
    }

    private var connectedBrands: Set<ControllerBrand> {
        Set(controllerService.controllerDetails.values.map { $0.brand }.filter { $0 != .unknown })
    }

    private var controllerChoices: [ControllerBrand] {
        [.dualSense, .dualShock4, .xbox, .switchPro, .eightBitDo, .stadia, .mfiGeneric]
    }

    private var stepSubtitle: String {
        switch step {
        case .category:   return "Step 1 of 5 · Choose what you're setting up"
        case .item:       return "Step 2 of 5 · Pick the title"
        case .controller: return "Step 3 of 5 · Pick your controller"
        case .options:    return "Step 4 of 5 · Options"
        case .finish:     return "Step 5 of 5 · Name & save"
        }
    }

    private func catTitle(_ c: SmartPresetProfile.Category) -> String {
        switch c {
        case .game:     return "Play a game"
        case .app:      return "Work in an app"
        case .workflow: return "A workflow"
        }
    }

    private func catDesc(_ c: SmartPresetProfile.Category) -> String {
        switch c {
        case .game:     return "Roblox, Minecraft, Elden Ring, and more"
        case .app:      return "Blender, Photoshop, Word, video editors, and more"
        case .workflow: return "Desktop, web, media, presenting, accessibility"
        }
    }

    private func summaryRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
        }
        .font(.caption)
    }
}


/// A quiet rotating pill of one-line feature tips, ported from YapToText's
/// QuickTipsPill. The text swaps on a slow clock with NO animated transaction
/// and the pill keeps a stable single-Text structure.
private struct QuickTipsPill: View {
    private static let tips: [String] = [
        "Press \u{2303}\u{2325}\u{2318}P anywhere to toggle your most recent preset, even while a game is in front (enable it in Settings).",
        "The Smart Preset Maker builds a tailored preset from a few questions: pick a game, answer, done.",
        "Gyro aim: bind gyro yaw to mouse X and pitch to mouse Y for motion aiming in any app.",
        "The DualSense touchpad can drive your Mac's cursor while a second finger scrolls.",
        "Turbo any button to rapid-fire it, or flip a binding to Toggle to latch it on and off.",
        "Macros chain keystrokes with per-step timing, and can mix keys, clicks, and MIDI in one sequence.",
        "Sticks and triggers can send MIDI notes and CC dials straight into GarageBand, Logic, or Ableton.",
        "A preset can auto-activate when its app comes to the front, then step aside when you leave.",
        "Set the DualSense light bar per preset so you can see which mapping is live from across the room.",
        "Everything runs and stays on your Mac. No telemetry, no account, nothing uploaded.",
        "Import presets with the tray icon in the bottom bar; export any preset from its right-click menu.",
        "Hide the Dock icon in Settings to run InputConfig as a quiet menu bar app.",
        "The editor has unlimited undo: \u{2318}Z and \u{2318}\u{21E7}Z work through every change.",
        "Click any control on the Live Visualizer to jump straight to its binding in the editor.",
    ]

    @State private var index = Int.random(in: 0..<QuickTipsPill.tips.count)
    @State private var rotator: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "lightbulb.max").iconTint(.accentColor).font(.caption)
            Text(Self.tips[index])
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .onAppear {
            rotator?.cancel()
            rotator = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 9_000_000_000)
                    guard !Task.isCancelled else { return }
                    index = (index + 1) % Self.tips.count
                }
            }
        }
        .onDisappear { rotator?.cancel(); rotator = nil }
        .accessibilityLabel("Tip: \(Self.tips[index])")
    }
}

// MARK: - Debug automation hooks (marketing / QA)

/// DEBUG-only view modifier that lets the app be driven from the shell via
/// DistributedNotificationCenter, so marketing captures and QA can navigate
/// without clicking. Wrapped in `#if DEBUG` so none of it can ship in a
/// Release build. Where a command needs a target preset, its name rides in
/// the notification's `object` (distributed notifications carry a string
/// object across processes).
///
/// Commands (post the name; pass the preset name as the object where noted):
///   inputconfig.debug.welcome            show the welcome screen
///   inputconfig.debug.select    <name>   select a preset (detail view)
///   inputconfig.debug.edit      [name]   open the binding editor
///   inputconfig.debug.activate  [name]   activate a preset (engine running)
///   inputconfig.debug.deactivate         stop the active preset
///   inputconfig.debug.sheet     <which>  smartmaker|stats|settings|motion|touchpad
///   inputconfig.debug.demo      <kind>   open a feature demo by raw value
///   inputconfig.debug.closesheets        dismiss any open sheet
struct DebugAutomationHooks: ViewModifier {
    let presetStore: PresetStore
    @Binding var selectedPresetId: UUID?
    @Binding var editingPreset: Preset?
    @Binding var showingSmartMaker: Bool
    @Binding var showingStats: Bool
    @Binding var showingSettingsSheet: Bool
    @Binding var showingMotion: Bool
    @Binding var showingTouchpad: Bool
    @Binding var presentedDemoKind: FeatureDemoKind?
    let onToggle: (Preset) -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .onReceive(dnc("inputconfig.debug.welcome")) { _ in
                editingPreset = nil
                selectedPresetId = nil
            }
            .onReceive(dnc("inputconfig.debug.select")) { note in
                if let p = preset(note) {
                    editingPreset = nil
                    selectedPresetId = p.id
                }
            }
            .onReceive(dnc("inputconfig.debug.edit")) { note in
                if let p = preset(note) ?? selected() {
                    selectedPresetId = p.id
                    editingPreset = p
                }
            }
            .onReceive(dnc("inputconfig.debug.activate")) { note in
                if let p = preset(note) ?? selected() {
                    selectedPresetId = p.id
                    if !p.isActive { onToggle(p) }
                }
            }
            .onReceive(dnc("inputconfig.debug.deactivate")) { _ in
                if let active = presetStore.presets.first(where: { $0.isActive }) {
                    onToggle(active)
                }
            }
            .onReceive(dnc("inputconfig.debug.sheet")) { note in
                closeSheets()
                editingPreset = nil
                switch note.object as? String {
                case "smartmaker": showingSmartMaker = true
                case "stats": showingStats = true
                case "settings": showingSettingsSheet = true
                case "motion": showingMotion = true
                case "touchpad": showingTouchpad = true
                default: break
                }
            }
            .onReceive(dnc("inputconfig.debug.demo")) { note in
                closeSheets()
                if let raw = note.object as? String,
                   let kind = FeatureDemoKind(rawValue: raw) {
                    presentedDemoKind = kind
                }
            }
            .onReceive(dnc("inputconfig.debug.closesheets")) { _ in
                closeSheets()
            }
        #else
        content
        #endif
    }

    #if DEBUG
    private func dnc(_ name: String) -> NotificationCenter.Publisher {
        // DistributedNotificationCenter's publisher yields on an arbitrary
        // queue; onReceive delivers on the main run loop, so state mutation
        // here is safe.
        DistributedNotificationCenter.default().publisher(for: Notification.Name(name))
    }
    private func preset(_ note: Notification) -> Preset? {
        (note.object as? String).flatMap { n in
            presetStore.presets.first(where: { $0.name == n })
        }
    }
    private func selected() -> Preset? {
        selectedPresetId.flatMap { id in presetStore.presets.first(where: { $0.id == id }) }
    }
    private func closeSheets() {
        showingSmartMaker = false
        showingStats = false
        showingSettingsSheet = false
        showingMotion = false
        showingTouchpad = false
        presentedDemoKind = nil
    }
    #endif
}

// MARK: - Debug marketing state (drives sub-views into capture-ready states)

#if DEBUG
/// A tiny shared, DEBUG-only observable that the marketing capture pipeline
/// toggles via DistributedNotificationCenter to put deep sub-views (the
/// binding editor's advanced options, the visualizer's edit-layout mode, the
/// One-Stick Driving arena) into a screenshot-ready state without clicking.
import Combine
@MainActor
final class DebugMarketing: ObservableObject {
    static let shared = DebugMarketing()
    @Published var expandOptions = false
    @Published var editLayout = false
    @Published var oneStick = false
    @Published var fakeController = false
    @Published var vizScale: Double?
    private init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("inputconfig.debug.fakecontroller"), object: nil, queue: .main) { [weak self] _ in
            self?.fakeController.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.zoom"), object: nil, queue: .main) { [weak self] note in
            if let v = (note.object as? String).flatMap(Double.init) { self?.vizScale = v }
        }
        dnc.addObserver(forName: .init("inputconfig.debug.expandOptions"), object: nil, queue: .main) { [weak self] _ in
            self?.expandOptions.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.editLayout"), object: nil, queue: .main) { [weak self] _ in
            self?.editLayout.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.oneStick"), object: nil, queue: .main) { [weak self] _ in
            self?.oneStick.toggle()
        }
    }
}
#endif

extension View {
    /// DEBUG-only: expands this binding row's advanced options when the
    /// marketing pipeline toggles DebugMarketing.expandOptions. No-op in Release.
    @ViewBuilder func debugExpandOptions(_ showAdvanced: Binding<Bool>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$expandOptions) { if $0 { showAdvanced.wrappedValue = true } }
        #else
        self
        #endif
    }

    /// DEBUG-only: engages the visualizer's Edit Layout mode on toggle.
    @ViewBuilder func debugEditLayout(_ editMode: Binding<Bool>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$editLayout) { editMode.wrappedValue = $0 }
        #else
        self
        #endif
    }

    /// DEBUG-only: expands and enables the One-Stick Driving section + arena.
    @ViewBuilder func debugOneStick(expanded: Binding<Bool>, enable: Binding<Bool>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$oneStick) {
            if $0 { expanded.wrappedValue = true; enable.wrappedValue = true }
        }
        #else
        self
        #endif
    }

    /// DEBUG-only: injects / removes the two synthetic marketing controllers so
    /// captures show a populated sidebar and visualizer with no hardware.
    @ViewBuilder func debugFakeController(_ service: GameControllerService) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$fakeController) { service.setMarketingFakeControllers($0) }
        #else
        self
        #endif
    }

    /// DEBUG-only: sets the live visualizer's zoom for marketing captures.
    @ViewBuilder func debugVizZoom(_ scale: Binding<Double>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$vizScale) { if let v = $0 { scale.wrappedValue = v } }
        #else
        self
        #endif
    }

    /// DEBUG-only: presents the deadzone-calibration and one-stick-driving
    /// views as standalone sheets for marketing capture. No-op in Release.
    @ViewBuilder func debugCaptureSheets() -> some View {
        #if DEBUG
        modifier(DebugCaptureSheets())
        #else
        self
        #endif
    }
}

#if DEBUG
/// DEBUG-only: drives the deadzone calibrator (joystick axis 0, trigger axis 4)
/// and the One-Stick Driving arena into standalone sheets via distributed
/// notifications, so marketing captures don't depend on fragile clicks.
///   inputconfig.debug.deadzone <axisIndex>   0/2 = stick, 4/5 = trigger
///   inputconfig.debug.drive                  one-stick driving arena
struct DebugCaptureSheets: ViewModifier {
    @State private var deadzoneAxis: Int?
    @State private var dz: Double = 0.18
    @State private var odz: Double = 0.9
    @State private var showDrive = false
    @State private var driveCfg: DriveConfig? = {
        var c = DriveConfig(); c.enabled = true; return c
    }()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { deadzoneAxis != nil },
                                        set: { if !$0 { deadzoneAxis = nil } })) {
                if let ax = deadzoneAxis {
                    DeadzoneCalibrationView(axisIndex: ax, deadzone: $dz, outerDeadzone: $odz,
                                            isInverted: false, onClose: { deadzoneAxis = nil })
                        .padding(24)
                        .frame(minWidth: 560, minHeight: 640)
                        .glassBackground()
                }
            }
            .sheet(isPresented: $showDrive) {
                ScrollView { DriveModeSection(driveConfig: $driveCfg).padding(28) }
                    .frame(minWidth: 760, minHeight: 720)
                    // Marketing capture only: suppress the macOS keyboard focus
                    // ring the sheet auto-draws on the disclosure control, which
                    // showed up as a stray bordered box over the section title.
                    .focusEffectDisabled()
                    .glassBackground()
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("inputconfig.debug.deadzone"))) { note in
                deadzoneAxis = (note.object as? String).flatMap { Int($0) } ?? 0
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("inputconfig.debug.drive"))) { _ in
                showDrive = true
            }
    }
}
#endif
