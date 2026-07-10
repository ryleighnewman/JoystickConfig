import SwiftUI

/// Compact readout of the InputConfig process's live resource use:
/// CPU%, resident memory, thread count, and a coarse "energy impact"
/// number. Lives in Settings → General so the user can confirm a
/// polling-rate or preset change didn't blow up CPU/RAM. Subscribes
/// to `SystemStatsService` only while visible to avoid burning a 1 Hz
/// timer when the panel isn't on screen.
struct SystemStatsPanel: View {
    @ObservedObject private var stats = SystemStatsService.shared

    var body: some View {
        let s = stats.current
        let c = stats.cumulative
        let p = stats.power
        VStack(alignment: .leading, spacing: 12) {
            Text("Live resource usage. Updates once per second.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // --- Snapshot tiles ---
            HStack(spacing: 24) {
                statTile(label: "CPU",
                         value: String(format: "%.1f%%", s.smoothedCpuPercent),
                         hint: "One core saturated = 100%",
                         color: cpuTint(for: s.smoothedCpuPercent))
                statTile(label: "Memory",
                         value: String(format: "%.0f MB", s.residentMemoryMB),
                         hint: "Resident set size",
                         color: memoryTint(for: s.residentMemoryMB))
                statTile(label: "Threads",
                         value: "\(s.threadCount)",
                         hint: "Live thread count",
                         color: .secondary)
                statTile(label: "Energy",
                         value: "\(s.energyImpact)",
                         hint: "Blended CPU + threads (0-100)",
                         color: energyTint(for: s.energyImpact))
            }

            // Mini CPU sparkline over the last minute. Drawn as a
            // simple GeometryReader path - no shapes per sample, no
            // per-frame allocations.
            sparkline
                .frame(height: 28)

            Divider()

            // --- Session totals ---
            HStack(spacing: 6) {
                Text("Session totals")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { stats.resetSessionStats() }
                    .buttonStyle(.solidSecondaryCompact)
                    .controlSize(.small)
                    .help("Zero out session uptime, peaks, averages, and energy estimate.")
            }
            HStack(spacing: 24) {
                statTile(label: "Uptime",
                         value: formatDuration(c.sessionUptime),
                         hint: "Since app launch / last reset",
                         color: .secondary)
                statTile(label: "Avg CPU",
                         value: String(format: "%.1f%%", c.averageCpuPercent),
                         hint: "Running mean of all samples",
                         color: cpuTint(for: c.averageCpuPercent))
                statTile(label: "Peak CPU",
                         value: String(format: "%.1f%%", c.peakCpuPercent),
                         hint: "Highest CPU% in session (100% = one core, like Activity Monitor)",
                         color: cpuTint(for: c.peakCpuPercent))
                statTile(label: "Peak Mem",
                         value: String(format: "%.0f MB", c.peakMemoryMB),
                         hint: "High-water mark",
                         color: memoryTint(for: c.peakMemoryMB))
            }
            HStack(spacing: 24) {
                statTile(label: "Energy used",
                         value: formatEnergy(c.estimatedEnergyJoules),
                         hint: "Coarse estimate, CPU × time",
                         color: .secondary)
                statTile(label: "Poll ticks",
                         value: formatBigNumber(c.controllerPollsCounted),
                         hint: "Controller frames since launch",
                         color: .secondary)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }

            // --- Power / battery ---
            if p.source != nil || p.batteryPercent != nil {
                Divider()
                Text("Power")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    statTile(label: "Source",
                             value: p.source ?? "Unknown",
                             hint: "Mains or battery",
                             color: powerSourceColor(p.source))
                    if let pct = p.batteryPercent {
                        statTile(label: "Battery",
                                 value: "\(pct)%",
                                 hint: p.batteryState ?? "",
                                 color: batteryTint(for: pct))
                    }
                    if abs(p.batteryDeltaPercent) >= 0.5 {
                        let delta = p.batteryDeltaPercent
                        statTile(label: "Δ since start",
                                 value: String(format: "%+.0f%%", -delta),
                                 hint: "Negative = drained while running",
                                 color: delta > 0 ? .orange : .green)
                    }
                    if let mins = p.minutesRemaining {
                        statTile(label: "Time left",
                                 value: "\(mins) min",
                                 hint: "Est. to empty / full",
                                 color: .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { stats.retain() }
        .onDisappear { stats.release() }
    }

    // MARK: - Formatting

    /// "1h 02m 13s" / "13m 09s" / "47s". Compact, monospace-friendly.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, r) }
        return "\(r)s"
    }

    /// Joules → human units. <1 kJ stays in J; otherwise kJ. Includes
    /// a Wh equivalent in the tooltip when over a minute of energy.
    private func formatEnergy(_ joules: Double) -> String {
        if joules < 1000 { return String(format: "%.0f J", joules) }
        return String(format: "%.1f kJ", joules / 1000.0)
    }

    /// 1234567 → "1.23M", 12345 → "12.3K". Reads cleanly in a tile.
    private func formatBigNumber(_ n: UInt64) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fK", Double(n) / 1000) }
        if n < 1_000_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        return String(format: "%.2fB", Double(n) / 1_000_000_000)
    }

    private func powerSourceColor(_ s: String?) -> Color {
        guard let s = s else { return .secondary }
        if s.lowercased().contains("battery") { return .orange }
        return .green
    }

    private func batteryTint(for pct: Int) -> Color {
        if pct <= 15 { return .red }
        if pct <= 35 { return .orange }
        return .green
    }

    @ViewBuilder
    private func statTile(label: String, value: String, hint: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .foregroundStyle(color)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sparkline: some View {
        GeometryReader { proxy in
            let pts = stats.history
            // Cap the y-scale at 100% by default; if any sample
            // exceeded that (multi-core saturation), grow proportionally.
            let maxVal = max(100.0, pts.map(\.smoothedCpuPercent).max() ?? 100)
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack(alignment: .bottomLeading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.08))

                // Path
                if pts.count >= 2 {
                    Path { p in
                        let stepX = w / CGFloat(max(1, pts.count - 1))
                        for (i, sample) in pts.enumerated() {
                            let x = CGFloat(i) * stepX
                            let y = h - CGFloat(sample.smoothedCpuPercent / maxVal) * h
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.accentColor, lineWidth: 1.5)
                }
            }
        }
    }

    private func cpuTint(for v: Double) -> Color {
        if v > 80 { return .red }
        if v > 40 { return .orange }
        return .green
    }

    private func memoryTint(for mb: Double) -> Color {
        if mb > 500 { return .red }
        if mb > 250 { return .orange }
        return .secondary
    }

    private func energyTint(for impact: Int) -> Color {
        if impact > 70 { return .red }
        if impact > 35 { return .orange }
        return .green
    }
}
