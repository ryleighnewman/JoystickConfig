import Foundation
import Darwin
import Combine
import IOKit
import IOKit.ps

/// Live process-level resource stats for the InputConfig process:
/// CPU usage, resident memory, virtual memory, thread count, and a
/// coarse "energy impact" approximation. Polled at 1 Hz so the UI
/// can show a small running readout without measurably affecting the
/// app's own footprint.
///
/// Everything is read via public Darwin APIs - no private symbols, no
/// extra entitlements. Safe for App Store distribution.
@MainActor
final class SystemStatsService: ObservableObject {

    static let shared = SystemStatsService()

    /// Snapshot of one tick. All values are point-in-time; the
    /// "smoothed" variants are exponentially weighted moving averages
    /// to reduce flicker in the UI.
    struct Snapshot: Equatable {
        var cpuPercent: Double          // 0...100×coreCount
        var smoothedCpuPercent: Double  // EWMA, smoother for display
        var residentMemoryBytes: UInt64
        var virtualMemoryBytes: UInt64
        var threadCount: Int
        /// Coarse impact 0-100: blends CPU% with thread count.
        var energyImpact: Int
        var sampledAt: Date
    }

    /// Cumulative + over-time stats tracked across the whole session.
    /// `Cumulative` values are updated every sample and reset on
    /// service init; they never decrement. `power` is sampled less
    /// often (every 5 s) because IOPSCopyPowerSourcesInfo is a
    /// non-trivial syscall.
    struct Cumulative: Equatable {
        /// Wall-clock seconds since the service started polling.
        var sessionUptime: TimeInterval = 0
        /// Highest CPU% seen in this session (any single sample).
        var peakCpuPercent: Double = 0
        /// Running mean CPU% over the whole session.
        var averageCpuPercent: Double = 0
        /// Highest resident memory in MB seen this session.
        var peakMemoryMB: Double = 0
        /// Crude "energy used" estimate in joules. Computed as
        /// (CPU% / 100) * sample-interval * estimated-package-watts.
        /// Not calibrated against real measurements - it's a relative
        /// "how much have we cost over time" signal.
        var estimatedEnergyJoules: Double = 0
        /// Sum of all controller poll ticks since the engine first
        /// ran this session. Bumped externally via
        /// `recordControllerPolls(_:)`.
        var controllerPollsCounted: UInt64 = 0
    }

    /// Power-source / battery info pulled from
    /// IOPSCopyPowerSourcesInfo. Optional because desktop Macs don't
    /// have a battery so all fields are nil there.
    struct PowerInfo: Equatable {
        /// "AC Power" or "Battery Power".
        var source: String?
        /// 0...100. nil on AC-only machines.
        var batteryPercent: Int?
        /// "Charging", "Discharging", "Charged", "Not Charging".
        var batteryState: String?
        /// Minutes to full / minutes to empty when known.
        var minutesRemaining: Int?
        /// % delta since the service started, capturing drain rate.
        /// Positive = lost charge, negative = gained charge.
        var batteryDeltaPercent: Double = 0
        /// Time the battery started at `initialBatteryPercent`.
        fileprivate var startedAt: Date = Date()
        fileprivate var initialBatteryPercent: Int?
    }

    @Published private(set) var current: Snapshot = Snapshot(
        cpuPercent: 0,
        smoothedCpuPercent: 0,
        residentMemoryBytes: 0,
        virtualMemoryBytes: 0,
        threadCount: 0,
        energyImpact: 0,
        sampledAt: Date()
    )

    /// Rolling buffer for sparkline rendering. Last 60 samples.
    @Published private(set) var history: [Snapshot] = []

    /// Session-cumulative + over-time stats. Reset to defaults whenever
    /// the user clicks "Reset session stats" in the panel.
    @Published private(set) var cumulative: Cumulative = Cumulative()

    /// Latest power / battery info. Updated every 5 s.
    @Published private(set) var power: PowerInfo = PowerInfo()

    /// Wall clock at first sample. Drives sessionUptime and battery delta.
    private var sessionStartedAt: Date = Date()
    /// Number of samples taken this session - used to compute running mean.
    private var sampleCount: UInt64 = 0
    /// Plain (non-published) controller-poll counter. The 120 Hz poll hook
    /// bumps this; sample() folds it into the published `cumulative` at 1 Hz
    /// so the Session Stats panel is not re-rendered at the input poll rate.
    private var pollCounter: UInt64 = 0
    /// Coarse package-watts estimate used for the energy approximation.
    /// Apple Silicon laptops in light use sit around 3-6 W package power;
    /// 5 W is a fair middle. Not a measurement - tunable constant.
    private let estimatedPackageWatts: Double = 5.0
    /// Wall-clock of the last power sample so we throttle to 5 s.
    private var lastPowerSampleAt: TimeInterval = 0

    private var timer: Timer?
    private var retainCount = 0
    /// IOKit push notification that fires the moment the power source set
    /// changes (plug / unplug), so the engine's auto rate switch and the
    /// Settings readout react immediately instead of waiting for the next
    /// 5-second poll tick.
    private var powerChangeSource: CFRunLoopSource?

    /// Last task_info CPU snapshot - we diff against this to compute
    /// the percentage in the user-visible "% of one core" form
    /// (`100.0` = one core saturated; `cpuPercent / numCores * 100` is
    /// the macOS Activity Monitor value).
    private var lastTotalCPUTime: Double?
    private var lastSampleWallClock: TimeInterval?

    private let smoothingFactor = 0.25  // EWMA: 0 = no smoothing, 1 = no history

    private init() {}

    // MARK: - Lifecycle

    /// Reference-counted start so multiple views (Test Bench panel,
    /// stats sheet) can show stats without each starting/stopping a
    /// timer. First retain spins up the timer; last release stops it.
    func retain() {
        retainCount += 1
        if retainCount == 1 { start() }
    }

    func release() {
        retainCount = max(0, retainCount - 1)
        if retainCount == 0 { stop() }
    }

    private func start() {
        timer?.invalidate()
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Push notification for plug / unplug. IOPS fires this callback the
        // moment the power source set changes, so `power` updates immediately
        // instead of waiting up to 5 s for the next poll tick. The context is
        // unretained-safe: the source is torn down in stop(), and this
        // singleton never deallocates anyway.
        if powerChangeSource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let src = IOPSNotificationCreateRunLoopSource({ ctx in
                guard let ctx else { return }
                let service = Unmanaged<SystemStatsService>.fromOpaque(ctx).takeUnretainedValue()
                Task { @MainActor in service.powerSourcesDidChange() }
            }, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
                powerChangeSource = src
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let src = powerChangeSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            powerChangeSource = nil
        }
    }

    /// IOKit told us the power sources changed (plugged in / unplugged).
    /// Resample immediately and reset the throttle window so the regular
    /// 1 Hz tick doesn't double-sample right after.
    private func powerSourcesDidChange() {
        let now = Date()
        samplePower(now: now)
        lastPowerSampleAt = now.timeIntervalSince1970
    }

    // MARK: - Sampling

    /// Read task_info + thread_info to produce one snapshot. Runs on
    /// main actor at 1 Hz; cost per sample is sub-millisecond.
    private func sample() {
        // Fold the 120 Hz poll counter into the published snapshot at this
        // 1 Hz cadence so observers of `cumulative` re-render at most once a
        // second, not at the input poll rate.
        if cumulative.controllerPollsCounted != pollCounter {
            cumulative.controllerPollsCounted = pollCounter
        }
        let now = Date()
        let cpu = readCPUPercent(now: now.timeIntervalSince1970)
        let memInfo = readMemory()
        let threads = readThreadCount()

        let nextSmoothed = (1 - smoothingFactor) * current.smoothedCpuPercent
            + smoothingFactor * cpu

        // Coarse "energy impact": weights CPU% heaviest, adds a small
        // term for thread count past a baseline. Range 0-100. Not a
        // calibrated energy figure - just a single number users can
        // glance at to spot regression.
        let impact = Int(min(100, max(0,
            cpu * 0.85 + max(0, Double(threads) - 6) * 1.5
        )))

        let snap = Snapshot(
            cpuPercent: cpu,
            smoothedCpuPercent: nextSmoothed,
            residentMemoryBytes: memInfo.resident,
            virtualMemoryBytes: memInfo.virtual,
            threadCount: threads,
            energyImpact: impact,
            sampledAt: now
        )
        current = snap
        history.append(snap)
        if history.count > 60 { history.removeFirst(history.count - 60) }

        // Cumulative update. Runs every 1 s tick. Cheap arithmetic so
        // we accept the tiny per-tick overhead in exchange for a
        // live-updating Session Stats panel.
        sampleCount &+= 1
        let memMB = Double(memInfo.resident) / 1_048_576.0
        var c = cumulative
        c.sessionUptime = now.timeIntervalSince(sessionStartedAt)
        c.peakCpuPercent = max(c.peakCpuPercent, cpu)
        c.peakMemoryMB = max(c.peakMemoryMB, memMB)
        // Running mean via incremental update: mean_n = mean_{n-1}
        // + (x_n - mean_{n-1}) / n. Stays bounded; no overflow.
        let n = Double(sampleCount)
        c.averageCpuPercent += (cpu - c.averageCpuPercent) / n
        // Energy ≈ (CPU% / 100) * dt * watts. dt is 1.0 s here because
        // the timer fires once per second. cpu is in Activity Monitor
        // convention (100 = one core), so dividing by cores*100 yields the
        // fractional whole-package load. (With the old machine-normalized
        // cpu this line divided by cores twice and undercounted energy.)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let frac = min(1.0, max(0.0, cpu / (cores * 100.0)))
        c.estimatedEnergyJoules += frac * 1.0 * estimatedPackageWatts
        cumulative = c

        // Power info refreshes at 0.2 Hz. IOPS calls walk an IOKit
        // tree so 5 s is plenty for a UI badge. Skipped entirely on
        // machines where the first probe returned no battery (desktop
        // Macs, Mac Mini, etc.) since IOPS will keep returning nothing
        // and we'd just be burning microseconds every 5 s forever.
        let nowTs = now.timeIntervalSince1970
        if nowTs - lastPowerSampleAt >= 5.0 && hasBatteryProbe {
            samplePower(now: now)
            lastPowerSampleAt = nowTs
        }
    }

    /// `nil` until the first samplePower(); true if a battery source
    /// has ever been reported by IOPS, false if the system never reports
    /// one (desktop Mac). Used to gate the 0.2 Hz IOPS poll loop so it
    /// never runs on machines without a battery.
    private var hasBatteryProbe: Bool = true

    /// Reads IOPSCopyPowerSourcesInfo and folds it into `power`.
    /// Safe to call on the main actor; the underlying call is fast
    /// (~hundreds of microseconds) but we still throttle to 0.2 Hz.
    private func samplePower(now: Date) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return
        }
        guard let sources = IOPSCopyPowerSourcesList(blob)?
            .takeRetainedValue() as? [CFTypeRef] else {
            return
        }
        // First-call probe: if the system reports zero power sources,
        // this is a desktop Mac. Flip hasBatteryProbe so subsequent
        // sample ticks skip the IOPS call entirely.
        if sources.isEmpty {
            hasBatteryProbe = false
            return
        }

        var next = power

        // External power state. "AC Power" or "Battery Power".
        if let str = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
            next.source = str
        }

        for src in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, src)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let pct = info[kIOPSCurrentCapacityKey as String] as? Int {
                next.batteryPercent = pct
                if next.initialBatteryPercent == nil {
                    next.initialBatteryPercent = pct
                    next.startedAt = now
                }
                if let start = next.initialBatteryPercent {
                    next.batteryDeltaPercent = Double(start - pct)
                }
            }
            if let state = info[kIOPSPowerSourceStateKey as String] as? String {
                next.batteryState = state == kIOPSACPowerValue
                    ? "On AC"
                    : (state == kIOPSBatteryPowerValue ? "On battery" : state)
            }
            if let charging = info[kIOPSIsChargingKey as String] as? Bool, charging {
                next.batteryState = "Charging"
            }
            if let mins = info[kIOPSTimeToEmptyKey as String] as? Int, mins > 0 {
                next.minutesRemaining = mins
            } else if let mins = info[kIOPSTimeToFullChargeKey as String] as? Int, mins > 0 {
                next.minutesRemaining = mins
            }
        }
        power = next
    }

    /// External hook the MappingEngine calls each poll tick to bump
    /// the cumulative "total controller polls" counter, so the
    /// Session Stats panel can show how many input frames the app
    /// has processed in this session.
    func recordControllerPolls(_ added: Int = 1) {
        // Plain increment, no @Published mutation. sample() publishes it at 1 Hz.
        pollCounter &+= UInt64(added)
    }

    /// Wipe the session-cumulative + power-delta counters back to
    /// zero. Triggered by the "Reset session stats" button in the
    /// panel. Does not affect `history` (sparkline) since the user
    /// might want to keep the last minute of CPU visible.
    func resetSessionStats() {
        sessionStartedAt = Date()
        sampleCount = 0
        cumulative = Cumulative()
        pollCounter = 0
        power = PowerInfo()  // forces re-baseline of battery delta
        lastPowerSampleAt = 0
    }

    /// Returns the process's CPU usage as a percentage of TOTAL system
    /// capacity, where 100 means every core is fully loaded by us.
    ///
    /// Previous implementation returned per-core percent (one core
    /// saturated = 100, two cores = 200, ... up to NCPU × 100). That's
    /// the raw value `task_thread_times_info` deltas naturally produce
    /// because they sum CPU time across every running thread. Users
    /// reading "200%" on an 8-core machine reasonably thought the
    /// readout was broken; Activity Monitor uses the same convention
    /// only inside its per-process column header, not the cumulative
    /// load chart, so the convention was confusing here.
    ///
    /// Now we divide by the active processor count so 100% means "the
    /// app is saturating every core". A still-tabbed-out InputConfig
    /// is usually under 5%; with the engine running on a busy preset
    /// it ticks up into the 10-15% range on M-series hardware.
    private func readCPUPercent(now: TimeInterval) -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size
                                            / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(TASK_THREAD_TIMES_INFO),
                          $0,
                          &count)
            }
        }
        guard kr == KERN_SUCCESS else { return current.cpuPercent }

        let userSecs = Double(info.user_time.seconds)
            + Double(info.user_time.microseconds) / 1_000_000.0
        let sysSecs = Double(info.system_time.seconds)
            + Double(info.system_time.microseconds) / 1_000_000.0
        let totalCPU = userSecs + sysSecs

        defer {
            lastTotalCPUTime = totalCPU
            lastSampleWallClock = now
        }

        guard let prevCPU = lastTotalCPUTime,
              let prevWall = lastSampleWallClock,
              now > prevWall else {
            return 0
        }
        let cpuDelta = totalCPU - prevCPU
        let wallDelta = now - prevWall
        guard wallDelta > 0 else { return 0 }
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        // Activity Monitor convention: 100% = one core saturated (so the
        // value can exceed 100 on multicore work). The old version divided
        // by core count, which read "6%" on a 16-core machine while the
        // process was actually pegging a full core - directly contradicting
        // ps/Activity Monitor and hiding real CPU problems. Clamp at
        // cores*100 to catch sampling glitches.
        let pct = (cpuDelta / wallDelta) * 100.0
        return max(0, min(pct, cores * 100.0))
    }

    /// Returns (resident, virtual) memory in bytes for the current process.
    private func readMemory() -> (resident: UInt64, virtual: UInt64) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                            / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (UInt64(info.resident_size), UInt64(info.virtual_size))
    }

    /// Reads the current process's live thread count via task_info.
    private func readThreadCount() -> Int {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        let kr = task_threads(mach_task_self_, &list, &count)
        guard kr == KERN_SUCCESS, let list = list else { return 0 }
        // Free the array IOKit allocated for us.
        let size = vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride)
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: OpaquePointer(list))),
                      size)
        return Int(count)
    }
}

extension SystemStatsService.Snapshot {
    var residentMemoryMB: Double { Double(residentMemoryBytes) / 1_048_576.0 }
    var virtualMemoryMB: Double { Double(virtualMemoryBytes) / 1_048_576.0 }
}
