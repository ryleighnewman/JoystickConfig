import SwiftUI
import Charts

/// Lifetime statistics dashboard. Opened from the round chart icon in the
/// main window toolbar. Everything shown here is local - no telemetry leaves
/// the device.
/// One tile's worth of detail. Each `bigTiles` cell instantiates a
/// `StatTileView` with one of these and a click handler routes through
/// to the StatsView's sheet.
struct StatDetail: Identifiable {
    let id = UUID()
    let icon: String
    let tint: Color
    let value: String
    let label: String
    /// Plain-English explanation of what the number actually counts. Shown
    /// in the detail sheet so the user understands how each metric is
    /// gathered.
    let explanation: String
    /// Optional related rows ("see also") for richer drill-downs.
    var related: [(label: String, value: String)] = []
    /// Top inputs leaderboard (button presses / axis flicks / etc.). Drawn
    /// as a mini horizontal-bar chart inside the detail sheet.
    var topInputs: [(key: String, count: Int)]? = nil
    /// Top presets leaderboard.
    var topPresets: [(name: String, count: Int)]? = nil
    /// Top controllers leaderboard (seconds-of-connection per device).
    var topControllers: [(name: String, seconds: TimeInterval)]? = nil
    /// 14-day connection history in seconds-per-day, oldest first. Drawn
    /// as a sparkline / bar chart for tiles where it makes sense.
    var last14Days: [TimeInterval]? = nil
}

struct StatsView: View {
    @StateObject private var service: StatsServiceRef = StatsServiceRef()
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false
    @State var selectedDetail: StatDetail?
    /// Subscribed to live so the power tiles update once per second
    /// while the dashboard is open.
    @ObservedObject private var sysStats = SystemStatsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 12)

            // ScrollView sits flush against the sheet edges so the scroll
            // bar tracks against the outer edge of the window, not inset
            // by the sheet's padding.
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    bigTiles
                    sectionCard {
                        sectionHeader("Top presets by activation count")
                        presetsChart
                    }
                    sectionCard {
                        sectionHeader("Most-pressed inputs")
                        inputsSection
                    }
                    sectionCard {
                        sectionHeader("Time per controller")
                        controllersSection
                    }
                    sectionCard {
                        sectionHeader("Last 14 days connected")
                        timelineChart
                    }
                    sectionCard {
                        sectionHeader("Output mix")
                        outputsChart
                    }
                    sectionCard {
                        sectionHeader("Power & energy (this session)")
                        powerSection
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset Statistics", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SolidButton(tint: .red, prominent: false, size: .compact))
                .foregroundStyle(.red)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.solidSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 740, height: 720)
        .onAppear { sysStats.retain() }
        .onDisappear { sysStats.release() }
        .confirmationDialog("Reset all statistics?",
                            isPresented: $showResetConfirmation,
                            titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) {
                StatsService.shared.resetAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Lifetime counters, daily logs, and per-preset history will all return to zero. This cannot be undone.")
        }
        .sheet(item: $selectedDetail) { detail in
            StatDetailSheet(detail: detail)
                .glassBackground()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28))
                .iconTint(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(
                    Circle().fill(Color.accentColor.opacity(0.15))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Statistics")
                    .font(.title2.weight(.semibold))
                Text("Lifetime usage of InputConfig on this Mac. Local only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Big tiles

    private var bigTiles: some View {
        let s = service.stats
        // Helpers shared across multiple tiles so each detail sheet can
        // surface real breakdowns instead of a static explanation.
        let topInputs = service.topInputs.prefix(5).map { (key: $0.key, count: $0.count) }
        let topPresets = service.topPresets.prefix(5).map { (name: $0.name, count: $0.count) }
        let topCtrls = service.topControllers.prefix(5).map { (name: $0.name, seconds: $0.time) }
        let last14 = service.last14DaysConnected.map(\.seconds)

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
            StatTileView(detail: StatDetail(
                icon: "gamecontroller", tint: .blue,
                value: timeShort(s.totalConnectedTime),
                label: "Time with a controller",
                explanation: "Cumulative time any controller has been plugged in or paired since you first launched the app.",
                related: [
                    ("Days tracked", "\(service.daysTracked)"),
                    ("Average per day", service.daysTracked > 0
                        ? timeShort(s.totalConnectedTime / Double(service.daysTracked))
                        : "-")
                ],
                topControllers: topCtrls,
                last14Days: last14
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "play.fill", tint: .green,
                value: timeShort(s.totalEngineRunningTime),
                label: "Time with a preset active",
                explanation: "Total time the mapping engine has been running with a preset active and firing outputs.",
                related: [
                    ("Activations", "\(s.presetActivationCount)"),
                    ("Average per activation", s.presetActivationCount > 0
                        ? timeShort(s.totalEngineRunningTime / Double(s.presetActivationCount))
                        : "-"),
                    ("Connected vs active",
                        s.totalConnectedTime > 0
                        ? String(format: "%.1f%%", s.totalEngineRunningTime / s.totalConnectedTime * 100)
                        : "-")
                ],
                topPresets: topPresets
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "hand.point.up.left.fill", tint: .orange,
                value: bigNumber(s.totalButtonPresses),
                label: "Total button presses",
                explanation: "Every controller button press counts, across every preset and every controller. Hat / D-pad direction changes count too.",
                related: [
                    ("Average per minute (active)", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalButtonPresses) / (s.totalEngineRunningTime / 60)))
                        : "-")
                ],
                topInputs: topInputs
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "keyboard", tint: .indigo,
                value: bigNumber(s.totalKeyPresses),
                label: "Keystrokes sent",
                explanation: "Number of synthetic key events the engine has sent to macOS. One press + release = 2 events. Macros multiply this.",
                related: [
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalKeyPresses) / (s.totalEngineRunningTime / 60)))
                        : "-"),
                    ("Per button press", s.totalButtonPresses > 0
                        ? String(format: "%.2fx", Double(s.totalKeyPresses) / Double(s.totalButtonPresses))
                        : "-")
                ]
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "cursorarrow.click.2", tint: .pink,
                value: bigNumber(s.totalMouseClicks),
                label: "Mouse clicks sent",
                explanation: "Synthetic mouse-button events sent by the engine. Includes left, right, and middle clicks plus their releases.",
                related: [
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalMouseClicks) / (s.totalEngineRunningTime / 60)))
                        : "-")
                ]
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "music.note", tint: .purple,
                value: bigNumber(s.totalMidiEvents),
                label: "MIDI events sent",
                explanation: "Note-on, note-off, CC, pitch-bend, program change - every event sent to the virtual MIDI source counts.",
                related: [
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalMidiEvents) / (s.totalEngineRunningTime / 60)))
                        : "-")
                ]
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "cursorarrow.motionlines", tint: .teal,
                value: bigNumber(s.totalMouseMotionPixels),
                label: "Mouse motion (pixels)",
                explanation: "Total absolute pixel-delta the engine has moved the cursor. Stick aim, gyro aim, and touchpad mouse all contribute.",
                related: [
                    ("Inches (96 dpi)", String(format: "%.1f\"", Double(s.totalMouseMotionPixels) / 96.0)),
                    ("Miles equivalent", String(format: "%.4f mi", Double(s.totalMouseMotionPixels) / 96.0 / 63360.0)),
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalMouseMotionPixels) / (s.totalEngineRunningTime / 60))) + " px"
                        : "-")
                ]
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "scroll", tint: .mint,
                value: bigNumber(s.totalScrollTicks),
                label: "Scroll ticks",
                explanation: "Vertical + horizontal scroll wheel ticks the engine has emitted. Each click of a wheel = 1 tick.",
                related: [
                    ("Approx. lines scrolled", bigNumber(s.totalScrollTicks * 3))
                ]
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "rectangle.and.hand.point.up.left.fill", tint: .cyan,
                value: bigNumber(s.totalTouchpadFingerEvents),
                label: "Touchpad finger updates",
                explanation: "Each new position sample received from the DualSense / DualShock 4 touchpad helper counts as one event. Long sliding gestures generate many.",
                related: [
                    ("Per minute active", s.totalEngineRunningTime > 60
                        ? bigNumber(Int(Double(s.totalTouchpadFingerEvents) / (s.totalEngineRunningTime / 60)))
                        : "-")
                ]
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "bolt.fill", tint: .yellow,
                value: bigNumber(s.totalMacroExecutions),
                label: "Macros executed",
                explanation: "Number of times a macro binding has fired. Each macro chain counts once regardless of how many steps it contains.",
                related: [
                    ("Per activation", s.presetActivationCount > 0
                        ? String(format: "%.2f", Double(s.totalMacroExecutions) / Double(s.presetActivationCount))
                        : "-")
                ]
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "arrowtriangle.up.fill", tint: .red,
                value: "\(s.presetActivationCount)",
                label: "Preset activations",
                explanation: "Number of distinct times you've turned a preset on. Toggling off then back on counts as a fresh activation.",
                topPresets: topPresets
            ), onSelect: openDetail)
            StatTileView(detail: StatDetail(
                icon: "calendar", tint: .gray,
                value: "\(service.daysTracked)",
                label: "Days tracked",
                explanation: "Count of distinct calendar days with any controller activity (button press, preset activation, etc.).",
                related: [
                    ("Average / day", service.daysTracked > 0
                        ? timeShort(s.totalConnectedTime / Double(service.daysTracked))
                        : "-")
                ],
                last14Days: last14
            ), onSelect: openDetail)
        }
    }

    private func openDetail(_ detail: StatDetail) {
        selectedDetail = detail
    }

    // MARK: - Cards / Sections

    /// Lightly tinted rounded card behind each section. Gives the dashboard
    /// a more "designed" feel than bare dividers.
    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var presetsChart: some View {
        let top = service.topPresets
        if top.isEmpty {
            emptyHint("Activate a preset to start tracking.")
        } else {
            // Compact mini-bar leaderboard. Each row is the preset name, a
            // capsule sized by its share of the leader, and the raw
            // activation count. Same format as the inputs section below so
            // the two sections read as a unit and don't waste vertical space
            // on chart axes / annotations.
            let maxCount = max(1, top.first?.count ?? 1)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(top, id: \.name) { row in
                    leaderboardRow(
                        icon: "play.circle.fill",
                        iconColor: .green,
                        label: row.name,
                        count: row.count,
                        maxCount: maxCount,
                        barTint: .green
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var inputsSection: some View {
        let top = service.topInputs
        if top.isEmpty {
            emptyHint("Push a button on your controller while a preset is active to start tracking.")
        } else {
            let maxCount = max(1, top.first?.count ?? 1)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(top, id: \.key) { row in
                    leaderboardRow(
                        icon: iconForInputKey(row.key),
                        iconColor: .orange,
                        label: prettyInputLabel(row.key),
                        count: row.count,
                        maxCount: maxCount,
                        barTint: .orange
                    )
                }
            }
        }
    }

    /// One row in a compact horizontal leaderboard: icon, single-line label,
    /// filled capsule bar, count. Used by both the preset and input
    /// sections so they look like a single coherent unit.
    private func leaderboardRow(icon: String,
                                iconColor: Color,
                                label: String,
                                count: Int,
                                maxCount: Int,
                                barTint: Color) -> some View {
        HStack(spacing: 8) {
            IconView(name: icon, glyphHeight: 12)
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(label)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 200, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(barTint.gradient)
                        .frame(width: max(2, CGFloat(Double(count) / Double(maxCount)) * geo.size.width))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Text("\(count)×")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(count) times")
    }

    @ViewBuilder
    private var controllersSection: some View {
        let top = service.topControllers
        if top.isEmpty {
            emptyHint("Connect a controller and use it for a while.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(top, id: \.name) { row in
                    let conns = service.stats.controllerConnectionCount[row.name] ?? 0
                    HStack(spacing: 10) {
                        ControllerGlyph(height: 14)
                            .iconTint(.blue)
                            .accessibilityHidden(true)
                        Text(row.name)
                            .font(.callout)
                        Spacer()
                        Text("\(conns) connection\(conns == 1 ? "" : "s")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(timeShort(row.time))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.name)
                    .accessibilityValue("\(timeShort(row.time)), \(conns) connection\(conns == 1 ? "" : "s")")
                }
            }
        }
    }

    @ViewBuilder
    private var timelineChart: some View {
        let days = service.last14DaysConnected
        let secs = days.map(\.seconds)
        let total = secs.reduce(0, +)
        let peak = secs.max() ?? 0
        let activeDays = secs.filter { $0 > 0 }.count
        Chart(days, id: \.date) { day in
            BarMark(
                x: .value("Day", day.date, unit: .day),
                y: .value("Seconds", day.seconds)
            )
            .foregroundStyle(day.seconds > 0
                             ? Color.accentColor.gradient
                             : Color.secondary.opacity(0.25).gradient)
            .cornerRadius(3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Controller connection over the last 14 days")
        .accessibilityValue("\(timeShort(total)) total across \(activeDays) active \(activeDays == 1 ? "day" : "days"), busiest day \(timeShort(peak))")
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let secs = value.as(Double.self) {
                        Text(timeShort(secs))
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(height: 140)
    }

    @ViewBuilder
    private var outputsChart: some View {
        let s = service.stats
        let slices: [(name: String, count: Int, color: Color)] = [
            ("Keystrokes",       s.totalKeyPresses,        .indigo),
            ("Mouse clicks",     s.totalMouseClicks,       .pink),
            ("MIDI events",      s.totalMidiEvents,        .purple),
            ("Scroll ticks",     s.totalScrollTicks,       .mint),
            ("Macros",           s.totalMacroExecutions,   .yellow),
        ]
        let nonZero = slices.filter { $0.count > 0 }
        if nonZero.isEmpty {
            emptyHint("Fire some outputs while a preset is running to see your mix.")
        } else {
            let total = max(1, nonZero.reduce(0) { $0 + $1.count })
            HStack(alignment: .top, spacing: 18) {
                // Donut chart - sector per output kind.
                Chart(nonZero, id: \.name) { slice in
                    SectorMark(
                        angle: .value("Count", slice.count),
                        innerRadius: .ratio(0.55),
                        angularInset: 2
                    )
                    .cornerRadius(4)
                    .foregroundStyle(slice.color.gradient)
                }
                .frame(width: 140, height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Output mix")
                .accessibilityValue(nonZero
                    .map { "\($0.name) \(Int(Double($0.count) / Double(total) * 100)) percent" }
                    .joined(separator: ", "))

                // Legend with raw counts.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(nonZero, id: \.name) { slice in
                        HStack(spacing: 8) {
                            Circle().fill(slice.color).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(slice.name)
                                .font(.callout)
                            Spacer()
                            Text("\(slice.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("\(Int(Double(slice.count) / Double(total) * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(slice.name)
                        .accessibilityValue("\(slice.count), \(Int(Double(slice.count) / Double(total) * 100)) percent")
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Format helpers

    private func bigNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Live power / energy tiles. Pulls cumulative + battery info
    /// straight from `SystemStatsService`. Distinct from the Settings
    /// → System Performance panel: this one is part of the lifetime
    /// Statistics dashboard so power sits next to all the other
    /// session/usage charts.
    private var powerSection: some View {
        let c = sysStats.cumulative
        let p = sysStats.power
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                powerTile(label: "Uptime",
                          value: timeShort(c.sessionUptime),
                          icon: "clock",
                          tint: .secondary,
                          hint: "Time the engine + stats panel have been polling.")
                powerTile(label: "Energy used",
                          value: formatEnergy(c.estimatedEnergyJoules),
                          icon: "bolt.fill",
                          tint: .yellow,
                          hint: "Coarse estimate: CPU% × time × 5 W package.")
                powerTile(label: "Avg CPU",
                          value: String(format: "%.1f%%", c.averageCpuPercent),
                          icon: "cpu",
                          tint: cpuTint(for: c.averageCpuPercent),
                          hint: "Running mean since session start.")
                powerTile(label: "Peak CPU",
                          value: String(format: "%.1f%%", c.peakCpuPercent),
                          icon: "speedometer",
                          tint: cpuTint(for: c.peakCpuPercent),
                          hint: "Highest single sample this session.")
            }
            if p.source != nil || p.batteryPercent != nil {
                HStack(alignment: .top, spacing: 16) {
                    powerTile(label: "Source",
                              value: p.source ?? "Unknown",
                              icon: (p.source ?? "").lowercased().contains("battery")
                                    ? "battery.50" : "powerplug.fill",
                              tint: (p.source ?? "").lowercased().contains("battery")
                                    ? .orange : .green,
                              hint: "AC = wall power, Battery = on battery.")
                    if let pct = p.batteryPercent {
                        powerTile(label: "Battery",
                                  value: "\(pct)%",
                                  icon: batteryIcon(for: pct),
                                  tint: batteryTint(for: pct),
                                  hint: p.batteryState ?? "Charge level.")
                    }
                    if abs(p.batteryDeltaPercent) >= 0.5 {
                        let delta = -p.batteryDeltaPercent
                        powerTile(label: "Δ session",
                                  value: String(format: "%+.0f%%", delta),
                                  icon: delta < 0 ? "arrow.down.circle" : "arrow.up.circle",
                                  tint: delta < 0 ? .orange : .green,
                                  hint: "Battery change since the panel opened.")
                    }
                    if let mins = p.minutesRemaining {
                        powerTile(label: "Time left",
                                  value: "\(mins)m",
                                  icon: "hourglass",
                                  tint: .secondary,
                                  hint: "Estimate to empty or full.")
                    }
                }
            } else {
                Text("This Mac has no battery / power source data. Desktops show only CPU + energy estimates.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text("Energy is a coarse estimate (CPU% × duration × 5 W). Battery delta and source come from IOKit's power-source API; CPU values come from task_info().")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func powerTile(label: String, value: String, icon: String,
                           tint: Color, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                IconView(name: icon, glyphHeight: 12)
                    .iconTint(tint)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.monospacedDigit())
                .foregroundStyle(tint)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func formatEnergy(_ joules: Double) -> String {
        if joules < 1000 { return String(format: "%.0f J", joules) }
        return String(format: "%.1f kJ", joules / 1000.0)
    }

    private func cpuTint(for v: Double) -> Color {
        if v > 80 { return .red }
        if v > 40 { return .orange }
        return .green
    }

    private func batteryTint(for pct: Int) -> Color {
        if pct <= 15 { return .red }
        if pct <= 35 { return .orange }
        return .green
    }

    private func batteryIcon(for pct: Int) -> String {
        if pct >= 90 { return "battery.100" }
        if pct >= 65 { return "battery.75" }
        if pct >= 40 { return "battery.50" }
        if pct >= 15 { return "battery.25" }
        return "battery.0"
    }

    private func timeShort(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private func iconForInputKey(_ key: String) -> String {
        if key.hasPrefix("btn") { return "circle.fill" }
        if key.hasPrefix("axi") { return "arrow.left.and.right" }
        if key.hasPrefix("hat") { return "arrow.up.and.down.and.arrow.left.and.right" }
        if key.hasPrefix("tpd") { return "hand.point.up.left.fill" }
        if key.hasPrefix("tpr") { return "rectangle.dashed" }
        if key.hasPrefix("mtn") { return "gyroscope" }
        return "questionmark"
    }

    private func prettyInputLabel(_ key: String) -> String {
        if let event = InputEvent.parse(key) {
            return event.displayName
        }
        return key
    }
}

/// Thin observable wrapper around the singleton StatsService so the view
/// re-renders when its `@Published stats` changes. We can't observe the
/// singleton directly from `@StateObject` since it's nonisolated-unsafe, so
/// we mirror its state into this proxy.
@MainActor
final class StatsServiceRef: ObservableObject {
    @Published var stats: StatsService.PersistentStats
    @Published var topPresets: [(name: String, count: Int)]
    @Published var topInputs: [(key: String, count: Int)]
    @Published var topControllers: [(name: String, time: TimeInterval)]
    @Published var daysTracked: Int
    @Published var last14DaysConnected: [(date: Date, seconds: TimeInterval)]

    private nonisolated(unsafe) var timer: Timer?

    init() {
        let svc = StatsService.shared
        self.stats = svc.stats
        self.topPresets = svc.topPresets
        self.topInputs = svc.topInputs
        self.topControllers = svc.topControllers
        self.daysTracked = svc.daysTracked
        self.last14DaysConnected = svc.last14DaysConnected
        // Refresh once per second while the view is on screen.
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let t = self.timer { RunLoop.main.add(t, forMode: .common) }
    }

    deinit {
        // Capture the timer locally so we don't access an isolated property
        // from the nonisolated deinit. Invalidate it from the main run loop.
        let t = timer
        DispatchQueue.main.async { t?.invalidate() }
    }

    private var lastStatsTick: Int = -1

    func refresh() {
        let svc = StatsService.shared
        // Skip the republish when nothing changed since the last tick, so an
        // idle second does not re-render the whole stats view.
        guard svc.statsTick != lastStatsTick else { return }
        lastStatsTick = svc.statsTick
        stats = svc.stats
        topPresets = svc.topPresets
        topInputs = svc.topInputs
        topControllers = svc.topControllers
        daysTracked = svc.daysTracked
        last14DaysConnected = svc.last14DaysConnected
    }
}

/// One big-number tile. Lifts on hover + click reveals a detail sheet.
struct StatTileView: View {
    let detail: StatDetail
    let onSelect: (StatDetail) -> Void
    @State private var hovering: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            onSelect(detail)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: detail.icon)
                        .font(.title3)
                        .iconTint(detail.tint)
                        .accessibilityHidden(true)
                    Spacer()
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                Text(detail.value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(detail.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            // Uniform minimum height across the grid so every tile in
            // the LazyVGrid lines up regardless of label length.
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hovering
                          ? detail.tint.opacity(0.18)
                          : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(hovering ? detail.tint.opacity(0.55) : Color.clear,
                            lineWidth: 1)
            )
            .scaleEffect(reduceMotion ? 1.0 : (hovering ? 1.02 : 1.0))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        // macOS otherwise draws an accent focus ring around the first
        // focusable button when the sheet opens (the top-left tile gets
        // it). Disabling the focus effect keeps every tile visually
        // consistent.
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help("Details for \(detail.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(detail.label): \(detail.value)")
        .accessibilityHint("Opens details")
        .accessibilityAddTraits(.isButton)
    }
}

/// Modal that pops up when the user clicks a tile. Shows the metric, its
/// plain-English description, related stats, and (when the source data
/// allows it) a top-N leaderboard plus a 14-day sparkline so the user
/// gets a real drill-down instead of just a definition.
struct StatDetailSheet: View {
    let detail: StatDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: icon block + big number.
            HStack(spacing: 14) {
                Image(systemName: detail.icon)
                    .font(.system(size: 38))
                    .iconTint(detail.tint)
                    .frame(width: 56, height: 56)
                    .background(detail.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.label)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(detail.value)
                        .font(.system(size: 36, weight: .semibold).monospacedDigit())
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Explanation.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What this counts")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(detail.explanation)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Related stats.
                    if !detail.related.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("By the numbers")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(Array(detail.related.enumerated()), id: \.offset) { _, pair in
                                HStack {
                                    Text(pair.label)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(pair.value)
                                        .font(.callout.monospacedDigit())
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Top inputs leaderboard.
                    if let inputs = detail.topInputs, !inputs.isEmpty {
                        miniLeaderboard(
                            title: "Top inputs",
                            rows: inputs.map { (label: prettyInputLabel($0.key),
                                                value: "\($0.count)\u{00D7}",
                                                weight: Double($0.count)) },
                            tint: detail.tint)
                    }

                    // Top presets leaderboard.
                    if let presets = detail.topPresets, !presets.isEmpty {
                        miniLeaderboard(
                            title: "Top presets",
                            rows: presets.map { (label: $0.name,
                                                 value: "\($0.count)\u{00D7}",
                                                 weight: Double($0.count)) },
                            tint: detail.tint)
                    }

                    // Top controllers leaderboard (time-weighted).
                    if let ctrls = detail.topControllers, !ctrls.isEmpty {
                        miniLeaderboard(
                            title: "Top controllers",
                            rows: ctrls.map { (label: $0.name,
                                               value: timeStr($0.seconds),
                                               weight: $0.seconds) },
                            tint: detail.tint)
                    }

                    // 14-day sparkline.
                    if let last14 = detail.last14Days, !last14.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Last 14 days")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            sparkline(values: last14, tint: detail.tint)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.solid)
            }
        }
        .padding(22)
        .frame(width: 500, height: 540)
    }

    /// Mini horizontal-bar leaderboard. Three columns: label, weight bar,
    /// numeric value. Used for top inputs / top presets / top controllers.
    private func miniLeaderboard(
        title: String,
        rows: [(label: String, value: String, weight: Double)],
        tint: Color
    ) -> some View {
        let maxWeight = max(1, rows.first?.weight ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.label)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 170, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(tint.opacity(0.12))
                                Capsule()
                                    .fill(tint.gradient)
                                    .frame(width: max(2, CGFloat(row.weight / maxWeight) * geo.size.width))
                            }
                        }
                        .frame(height: 6)
                        .accessibilityHidden(true)
                        Text(row.value)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.label)
                    .accessibilityValue(row.value)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Compact bar-chart sparkline for the 14-day history.
    private func sparkline(values: [Double], tint: Color) -> some View {
        let maxValue = max(1, values.max() ?? 1)
        let total = values.reduce(0, +)
        let peak = values.max() ?? 0
        let activeDays = values.filter { $0 > 0 }.count
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Capsule()
                    .fill(v > 0 ? tint.gradient : Color.secondary.opacity(0.1).gradient)
                    .frame(width: 14, height: max(3, CGFloat(v / maxValue) * 60))
            }
        }
        .frame(height: 60)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 14 days")
        .accessibilityValue("\(timeStr(total)) total across \(activeDays) active \(activeDays == 1 ? "day" : "days"), busiest day \(timeStr(peak))")
    }

    private func timeStr(_ s: TimeInterval) -> String {
        let i = Int(s)
        if i < 60 { return "\(i)s" }
        if i < 3600 { return "\(i / 60)m" }
        if i < 86400 { return "\(i / 3600)h \((i % 3600) / 60)m" }
        return "\(i / 86400)d \((i % 86400) / 3600)h"
    }

    private func prettyInputLabel(_ key: String) -> String {
        if let event = InputEvent.parse(key) {
            return event.displayName
        }
        return key
    }
}
