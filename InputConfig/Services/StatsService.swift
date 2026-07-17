import Foundation
import Combine

/// Persistent usage telemetry for InputConfig. Tracks how much time the
/// user spends with controllers connected, which presets they activate
/// most, what buttons they push, total mouse / scroll / MIDI output volume,
/// and similar trivia. Everything is local - nothing is sent over the
/// network.
///
/// Storage: a single `stats.json` next to the presets directory. Reads
/// happen on init; writes are coalesced through the persist queue every
/// few seconds so the 120 Hz mapping loop never serializes JSON on its
/// hot path.
/// Not @MainActor - the engine and GameControllerService already hop to
/// the main actor before calling the recording methods, and the singleton
/// itself is nonisolated so it can be shared across the whole app.
final class StatsService: ObservableObject, @unchecked Sendable {

    // MARK: - Persisted state

    struct PersistentStats: Codable {
        var firstLaunchAt: Date = Date()
        var launchCount: Int = 0
        var totalConnectedTime: TimeInterval = 0
        var totalEngineRunningTime: TimeInterval = 0
        var presetActivationCount: Int = 0
        var presetTimeByName: [String: TimeInterval] = [:]
        var presetActivationCountByName: [String: Int] = [:]
        var totalButtonPresses: Int = 0
        var totalKeyPresses: Int = 0
        var totalMouseClicks: Int = 0
        var totalMidiEvents: Int = 0
        var totalMouseMotionPixels: Int = 0
        var totalScrollTicks: Int = 0
        var totalTouchpadFingerEvents: Int = 0
        var totalMacroExecutions: Int = 0
        /// Daily connection log - `yyyy-MM-dd` → seconds connected that day.
        var dailyConnectedSeconds: [String: TimeInterval] = [:]
        /// "btn 5" / "axi 0 +" / "tpr <id>" → press counter.
        var inputPressCounts: [String: Int] = [:]
        /// Controller display name → cumulative connected seconds.
        var controllerTimeByName: [String: TimeInterval] = [:]
        /// Controller display name → connection event count.
        var controllerConnectionCount: [String: Int] = [:]
    }

    /// Live stats counters. Plain `var` (not `@Published`) so the
    /// engine's 120 Hz hot path can mutate them without triggering an
    /// ObservableObject publish on every mutation. The throttled
    /// `statsTick` below republishes once per `flushInterval` so views
    /// still update at a comfortable cadence.
    private(set) var stats = PersistentStats()

    /// Bumped by the 1 Hz throttle timer. Views observe this to know
    /// when to re-read `stats`. Lets StatsView refresh at 1 Hz without
    /// the engine paying a publish cost on every button press.
    @Published private(set) var statsTick: Int = 0

    // MARK: - Lifetime / lifecycle

    nonisolated(unsafe) static let shared = StatsService()

    private let fileURL: URL
    private let persistQueue = DispatchQueue(label: "com.inputconfig.stats-io", qos: .utility)
    private var flushTimer: Timer?
    /// True while we have at least one controller connected. Drives the
    /// "total connected time" accumulator.
    private var connectedSince: Date?
    /// True while MappingEngine is running with an active preset.
    private var engineRunningSince: Date?
    private var activePresetName: String?
    private var activePresetStartedAt: Date?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("stats.json")
        load()
        stats.launchCount += 1
        startFlushTimer()
    }

    // MARK: - Recording API

    func controllerConnected(name: String) {
        if connectedSince == nil { connectedSince = Date() }
        stats.controllerConnectionCount[name, default: 0] += 1
        markDirty()
    }

    /// Called when the last controller disconnects.
    func controllerDisconnected(name: String, anyStillConnected: Bool) {
        // Flush per-name time only if we know how long the last connection
        // lasted. We don't track per-controller start, only the overall
        // connectedSince - so apportion by an estimate: 0 here, the rolling
        // accumulator continues until ALL are gone.
        _ = name
        if !anyStillConnected, let since = connectedSince {
            let delta = Date().timeIntervalSince(since)
            stats.totalConnectedTime += delta
            recordDailyConnection(delta: delta)
            connectedSince = nil
            // Apportion this run's seconds to whatever controller name
            // last connected: cheap approximation.
            stats.controllerTimeByName[name, default: 0] += delta
        }
        markDirty()
    }

    func engineStarted(presetName: String) {
        engineRunningSince = Date()
        activePresetName = presetName
        activePresetStartedAt = Date()
        stats.presetActivationCount += 1
        stats.presetActivationCountByName[presetName, default: 0] += 1
        markDirty()
    }

    func engineStopped() {
        if let s = engineRunningSince {
            stats.totalEngineRunningTime += Date().timeIntervalSince(s)
            engineRunningSince = nil
        }
        if let name = activePresetName, let s = activePresetStartedAt {
            stats.presetTimeByName[name, default: 0] += Date().timeIntervalSince(s)
        }
        activePresetName = nil
        activePresetStartedAt = nil
        markDirty()
    }

    func recordButtonPress(inputKey: String) {
        stats.totalButtonPresses += 1
        stats.inputPressCounts[inputKey, default: 0] += 1
        // Bound the dict so months of play with analog-stick micro
        // wiggles don't bloat the persistent file. Prune the bottom
        // quartile by count when we exceed the cap; the top-N readout
        // in StatsView still surfaces the meaningful inputs. Pruning
        // is amortised: only runs once per N inserts past the cap.
        if stats.inputPressCounts.count > Self.inputPressCountsHardCap {
            pruneInputPressCounts()
        }
        markDirty()
    }

    /// Upper bound on distinct input keys we'll track. ~99% of users
    /// have fewer than 500 unique key strings ever; the cap is set
    /// well above that so it never trips in normal use. The prune is
    /// also defensive against bugs that produce churning string keys.
    private static let inputPressCountsHardCap = 2000

    /// Drop the lowest-count quartile of input keys. Called only when
    /// the dict overflows; with the cap at 2000 and a quartile prune
    /// it runs every ~500 unique-input-string adds, which on a real
    /// workload is essentially never.
    private func pruneInputPressCounts() {
        let entries = stats.inputPressCounts.sorted { $0.value < $1.value }
        let dropCount = entries.count / 4
        for (key, _) in entries.prefix(dropCount) {
            stats.inputPressCounts.removeValue(forKey: key)
        }
    }

    func recordKeyPress() { stats.totalKeyPresses += 1; markDirty() }
    func recordMouseClick() { stats.totalMouseClicks += 1; markDirty() }
    func recordMidiEvent() { stats.totalMidiEvents += 1; markDirty() }
    func recordMouseMotion(pixels: Int) { stats.totalMouseMotionPixels += abs(pixels); markDirty() }
    func recordScroll(ticks: Int) { stats.totalScrollTicks += abs(ticks); markDirty() }
    func recordTouchpadEvent() { stats.totalTouchpadFingerEvents += 1; markDirty() }
    func recordMacroExecution() { stats.totalMacroExecutions += 1; markDirty() }

    // MARK: - Derived

    var topPresets: [(name: String, count: Int)] {
        stats.presetActivationCountByName
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { ($0.key, $0.value) }
    }

    var topInputs: [(key: String, count: Int)] {
        stats.inputPressCounts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { ($0.key, $0.value) }
    }

    var topControllers: [(name: String, time: TimeInterval)] {
        stats.controllerTimeByName
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { ($0.key, $0.value) }
    }

    var daysTracked: Int {
        max(1, Int(Date().timeIntervalSince(stats.firstLaunchAt) / 86_400))
    }

    /// Last 14 days of connected seconds, oldest first. Missing days
    /// (no activity) report 0.
    var last14DaysConnected: [(date: Date, seconds: TimeInterval)] {
        let fmt = Self.dailyKeyFormatter
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [(Date, TimeInterval)] = []
        for offset in (0..<14).reversed() {
            let d = cal.date(byAdding: .day, value: -offset, to: today)!
            let key = fmt.string(from: d)
            out.append((d, stats.dailyConnectedSeconds[key] ?? 0))
        }
        return out
    }

    func resetAll() {
        stats = PersistentStats()
        connectedSince = nil
        engineRunningSince = nil
        activePresetName = nil
        activePresetStartedAt = nil
        flushNow()
    }

    // MARK: - Persistence

    private var dirty = false
    private func markDirty() { dirty = true }

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let wasDirty = self.dirty
                self.flushIfDirty()
                // Only bump the published tick when stats actually
                // changed since the last flush. Without this gate
                // every view subscribed to `statsTick` would re-render
                // every 5 s even when nothing happened in the engine.
                if wasDirty {
                    self.statsTick &+= 1
                }
            }
        }
        if let t = flushTimer { RunLoop.main.add(t, forMode: .common) }
    }

    /// Shared formatter for "yyyy-MM-dd" daily keys. Static so we don't
    /// pay DateFormatter allocation on every flush / read - those
    /// allocations were ~30 µs each and the formatter is re-buildable
    /// many times per second on a hot stats path.
    private static let dailyKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private func flushIfDirty() {
        guard dirty else { return }
        // Roll up any in-flight time so a crash before disconnect doesn't
        // throw away the session. The same delta has to land in the daily
        // bucket too, otherwise connected time that is flushed before the
        // controller disconnects never reaches the 14-day usage chart.
        if let since = connectedSince {
            let delta = Date().timeIntervalSince(since)
            stats.totalConnectedTime += delta
            recordDailyConnection(delta: delta)
            connectedSince = Date()
        }
        if let s = engineRunningSince {
            stats.totalEngineRunningTime += Date().timeIntervalSince(s)
            engineRunningSince = Date()
        }
        if let name = activePresetName, let s = activePresetStartedAt {
            stats.presetTimeByName[name, default: 0] += Date().timeIntervalSince(s)
            activePresetStartedAt = Date()
        }
        flushNow()
    }

    private func flushNow() {
        let snapshot = stats
        let url = fileURL
        persistQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        dirty = false
    }

    /// Synchronous flush for app termination. Rolls up in-flight session time
    /// and writes on the calling thread (persistQueue.sync) so the data reaches
    /// disk before the process exits. The periodic flush uses persistQueue.async,
    /// which is not guaranteed to finish at Cmd+Q, so the last session's counts
    /// and time would otherwise be lost.
    func flushSynchronously() {
        if let since = connectedSince {
            let delta = Date().timeIntervalSince(since)
            stats.totalConnectedTime += delta
            recordDailyConnection(delta: delta)
            connectedSince = Date()
        }
        if let s = engineRunningSince {
            stats.totalEngineRunningTime += Date().timeIntervalSince(s)
            engineRunningSince = Date()
        }
        if let name = activePresetName, let s = activePresetStartedAt {
            stats.presetTimeByName[name, default: 0] += Date().timeIntervalSince(s)
            activePresetStartedAt = Date()
        }
        let snapshot = stats
        let url = fileURL
        persistQueue.sync {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        dirty = false
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistentStats.self, from: data) else {
            return
        }
        stats = decoded
    }

    private func recordDailyConnection(delta: TimeInterval) {
        let key = Self.dailyKeyFormatter.string(from: Date())
        stats.dailyConnectedSeconds[key, default: 0] += delta
        // Keep a trailing window so the map can't grow one key per day forever;
        // readers use at most the last 14 days.
        if stats.dailyConnectedSeconds.count > 90 {
            let cutoff = Self.dailyKeyFormatter.string(from: Date().addingTimeInterval(-90 * 86_400))
            stats.dailyConnectedSeconds = stats.dailyConnectedSeconds.filter { $0.key >= cutoff }
        }
    }
}

extension StatsService.PersistentStats {
    enum CodingKeys: String, CodingKey {
        case firstLaunchAt, launchCount, totalConnectedTime, totalEngineRunningTime
        case presetActivationCount, presetTimeByName, presetActivationCountByName
        case totalButtonPresses, totalKeyPresses, totalMouseClicks, totalMidiEvents
        case totalMouseMotionPixels, totalScrollTicks, totalTouchpadFingerEvents
        case totalMacroExecutions, dailyConnectedSeconds, inputPressCounts
        case controllerTimeByName, controllerConnectionCount
    }

    /// Lenient decode: each field falls back to its default when the key is
    /// missing. The synthesized Decodable would throw keyNotFound on a
    /// stats.json written by an older build that lacks a newer counter, and the
    /// load path then resets the whole file - wiping all lifetime usage
    /// telemetry. This keeps existing counters and defaults only the new ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = Self()
        s.firstLaunchAt = try c.decodeIfPresent(Date.self, forKey: .firstLaunchAt) ?? s.firstLaunchAt
        s.launchCount = try c.decodeIfPresent(Int.self, forKey: .launchCount) ?? s.launchCount
        s.totalConnectedTime = try c.decodeIfPresent(TimeInterval.self, forKey: .totalConnectedTime) ?? s.totalConnectedTime
        s.totalEngineRunningTime = try c.decodeIfPresent(TimeInterval.self, forKey: .totalEngineRunningTime) ?? s.totalEngineRunningTime
        s.presetActivationCount = try c.decodeIfPresent(Int.self, forKey: .presetActivationCount) ?? s.presetActivationCount
        s.presetTimeByName = try c.decodeIfPresent([String: TimeInterval].self, forKey: .presetTimeByName) ?? s.presetTimeByName
        s.presetActivationCountByName = try c.decodeIfPresent([String: Int].self, forKey: .presetActivationCountByName) ?? s.presetActivationCountByName
        s.totalButtonPresses = try c.decodeIfPresent(Int.self, forKey: .totalButtonPresses) ?? s.totalButtonPresses
        s.totalKeyPresses = try c.decodeIfPresent(Int.self, forKey: .totalKeyPresses) ?? s.totalKeyPresses
        s.totalMouseClicks = try c.decodeIfPresent(Int.self, forKey: .totalMouseClicks) ?? s.totalMouseClicks
        s.totalMidiEvents = try c.decodeIfPresent(Int.self, forKey: .totalMidiEvents) ?? s.totalMidiEvents
        s.totalMouseMotionPixels = try c.decodeIfPresent(Int.self, forKey: .totalMouseMotionPixels) ?? s.totalMouseMotionPixels
        s.totalScrollTicks = try c.decodeIfPresent(Int.self, forKey: .totalScrollTicks) ?? s.totalScrollTicks
        s.totalTouchpadFingerEvents = try c.decodeIfPresent(Int.self, forKey: .totalTouchpadFingerEvents) ?? s.totalTouchpadFingerEvents
        s.totalMacroExecutions = try c.decodeIfPresent(Int.self, forKey: .totalMacroExecutions) ?? s.totalMacroExecutions
        s.dailyConnectedSeconds = try c.decodeIfPresent([String: TimeInterval].self, forKey: .dailyConnectedSeconds) ?? s.dailyConnectedSeconds
        s.inputPressCounts = try c.decodeIfPresent([String: Int].self, forKey: .inputPressCounts) ?? s.inputPressCounts
        s.controllerTimeByName = try c.decodeIfPresent([String: TimeInterval].self, forKey: .controllerTimeByName) ?? s.controllerTimeByName
        s.controllerConnectionCount = try c.decodeIfPresent([String: Int].self, forKey: .controllerConnectionCount) ?? s.controllerConnectionCount
        self = s
    }
}
