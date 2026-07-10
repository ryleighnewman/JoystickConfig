import SwiftUI

/// Internal diagnostics window. Runs every automated test through
/// TestBenchService and exposes manual input injectors that let us verify
/// the OS-side outputs (keyboard, mouse, MIDI) on this Mac without owning
/// every controller variant the app supports.
struct TestBenchView: View {
    @StateObject private var service = TestBenchService.shared
    @State private var summary: String = ""
    @State private var filter: TestResult.Status? = nil
    @State private var selectedTab: Tab = .automated

    enum Tab: String, CaseIterable {
        case automated = "Automated Tests"
        case manual = "Manual Output Injectors"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            switch selectedTab {
            case .automated: automatedTab
            case .manual: manualTab
            }
        }
        .frame(minWidth: 700, minHeight: 540)
    }

    // MARK: - Automated tab

    private var automatedTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    Task {
                        let (passed, failed) = await service.runAll()
                        summary = "\(passed) passed · \(failed) failed"
                    }
                } label: {
                    Label(service.isRunning ? "Running..." : "Run All Tests",
                          systemImage: service.isRunning ? "hourglass" : "play.fill")
                }
                .buttonStyle(.solid)
                .disabled(service.isRunning)

                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Filter", selection: $filter) {
                    Text("All").tag(TestResult.Status?.none)
                    Text("Failed only").tag(TestResult.Status?.some(.fail))
                    Text("Passed only").tag(TestResult.Status?.some(.pass))
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredResults()) { result in
                        resultRow(result)
                        Divider().opacity(0.4)
                    }
                    if service.results.isEmpty {
                        ContentUnavailableView(
                            "No diagnostics yet",
                            systemImage: "play.rectangle",
                            description: Text("Click Run All Tests to exercise every subsystem of the app, then verify the results here.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ result: TestResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(result.status.rawValue)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(statusColor(result.status))
                .frame(width: 50, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(result.name)
                        .font(.caption)
                }
                Text(result.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(result.status == .fail ? Color.red.opacity(0.06) : Color.clear)
    }

    private func statusColor(_ s: TestResult.Status) -> Color {
        switch s {
        case .pass: return .green
        case .fail: return .red
        case .skipped: return .secondary
        case .info: return .blue
        }
    }

    private func filteredResults() -> [TestResult] {
        guard let filter = filter else { return service.results }
        return service.results.filter { $0.status == filter }
    }

    // MARK: - Manual tab

    private var manualTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section(title: "Keyboard & Mouse",
                        description: "Triggers our InputSimulator the same way an active preset would. Watch other apps to confirm the events are received.") {
                    keyboardMouseInjectors
                }

                section(title: "MIDI",
                        description: "Sends MIDI through the InputConfig virtual port. Use the loopback test above, or open a DAW and watch for these messages on the InputConfig source.") {
                    midiInjectors
                }

                section(title: "Haptics & Speech",
                        description: "Trigger feedback on the first connected controller, and speak through your Mac speakers.") {
                    feedbackInjectors
                }

                section(title: "Light Bar",
                        description: "Send light commands to any DualSense / DualShock connected on this Mac.") {
                    lightBarInjectors
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, description: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .padding(.top, 4)
            Divider()
        }
    }

    // MARK: - Keyboard / Mouse injectors

    private var keyboardMouseInjectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Type \"A\"") {
                    Task { @MainActor in
                        InputSimulator.shared.keyDown(4)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        InputSimulator.shared.keyUp(4)
                    }
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Press Space") {
                    Task { @MainActor in
                        InputSimulator.shared.keyDown(44)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        InputSimulator.shared.keyUp(44)
                    }
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Press Cmd+A") {
                    Task { @MainActor in
                        InputSimulator.shared.keyDown(227) // Left Cmd
                        InputSimulator.shared.keyDown(4)   // A
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        InputSimulator.shared.keyUp(4)
                        InputSimulator.shared.keyUp(227)
                    }
                }
                .buttonStyle(.solidSecondaryCompact)
            }
            HStack(spacing: 10) {
                Button("Move mouse right 100px") {
                    InputSimulator.shared.moveMouse(deltaX: 100, deltaY: 0)
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Move mouse down 100px") {
                    InputSimulator.shared.moveMouse(deltaX: 0, deltaY: 100)
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Left click") {
                    Task { @MainActor in
                        InputSimulator.shared.mouseButtonDown(0)
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        InputSimulator.shared.mouseButtonUp(0)
                    }
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Scroll up 5x") {
                    InputSimulator.shared.scrollWheel(deltaX: 0, deltaY: -5)
                }
                .buttonStyle(.solidSecondaryCompact)
            }
        }
    }

    // MARK: - MIDI injectors

    @State private var midiCC: Double = 64
    @State private var midiNote: Int = 60
    @State private var midiChannel: Int = 1

    private var midiInjectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Channel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $midiChannel) {
                    ForEach(1...16, id: \.self) { c in Text("\(c)").tag(c) }
                }
                .labelsHidden()
                .frame(width: 60)

                Text("Note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $midiNote) {
                    ForEach(0...127, id: \.self) { n in
                        Text("\(MIDIService.noteName(n)) (\(n))").tag(n)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            HStack(spacing: 10) {
                Button("Note On") {
                    MIDIService.shared.sendNoteOn(note: midiNote, velocity: 100, channel: midiChannel)
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Note Off") {
                    MIDIService.shared.sendNoteOff(note: midiNote, channel: midiChannel)
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("All Notes Off") {
                    MIDIService.shared.releaseAllNotes()
                }
                .buttonStyle(.solidSecondaryCompact)
            }

            HStack(spacing: 10) {
                Text("CC 1 value")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $midiCC, in: 0...127)
                    .frame(maxWidth: 220)
                    .onChange(of: midiCC) { _, v in
                        MIDIService.shared.sendCC(controller: 1, value: Int(v), channel: midiChannel)
                    }
                Text("\(Int(midiCC))")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 30, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Button("Pitch Bend Up") {
                    MIDIService.shared.sendPitchBend(value: 16383, channel: midiChannel)
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Pitch Bend Center") {
                    MIDIService.shared.sendPitchBend(value: 8192, channel: midiChannel)
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Pitch Bend Down") {
                    MIDIService.shared.sendPitchBend(value: 0, channel: midiChannel)
                }
                .buttonStyle(.solidSecondaryCompact)
            }
        }
    }

    // MARK: - Feedback injectors

    private var feedbackInjectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Vibrate controller 0") {
                    let controllers = GameControllerService.snapshotControllers()
                    if let first = controllers.first {
                        FeedbackService.shared.vibrate(controller: first, intensity: 0.7)
                    }
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Speak \"Hello\"") {
                    FeedbackService.shared.speak("Hello", destination: .mac)
                }
                .buttonStyle(.solidSecondaryCompact)
                Button("Speak \"Test\"") {
                    FeedbackService.shared.speak("Test 1 2 3", destination: .mac)
                }
                .buttonStyle(.solidSecondaryCompact)
            }
            Text("Vibration requires a controller with Core Haptics support (DualSense, DualSense Edge, etc.) connected.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Light Bar injectors

    private var lightBarInjectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                lightButton("Red", color: .red, r: 255, g: 0, b: 0)
                lightButton("Green", color: .green, r: 0, g: 255, b: 0)
                lightButton("Blue", color: .blue, r: 0, g: 0, b: 255)
                lightButton("White", color: .white, r: 255, g: 255, b: 255)
                lightButton("Off", color: .gray, r: 0, g: 0, b: 0)
            }
            Text("Requires a DualSense or DualShock 4 controller on this Mac. InputConfig will briefly stop the system game controller agent to send the report.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func lightButton(_ name: String, color: Color, r: UInt8, g: UInt8, b: UInt8) -> some View {
        Button {
            HIDLightController.shared.setLightColor(red: r, green: g, blue: b)
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(name).font(.caption)
            }
        }
        .buttonStyle(.solidSecondaryCompact)
    }
}

// MARK: - Window controller

@MainActor
final class TestBenchWindowController {
    static let shared = TestBenchWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: TestBenchView()
            .background(VisualEffectBackground().ignoresSafeArea()))
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "InputConfig Test Bench"
        newWindow.setContentSize(NSSize(width: 820, height: 600))
        // .fullSizeContentView lets the blur reach under the transparent
        // titlebar so the top bar isn't see-through to the desktop.
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
