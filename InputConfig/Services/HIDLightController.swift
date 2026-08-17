import Foundation
import GameController
import IOKit
import IOKit.hid

/// Controls DualSense / DualShock 4 light bars by invoking a helper tool
/// that runs as a separate process, kills the gamecontrolleragentd to release
/// the HID device, and sends the output report matching HIDAPI/SDL2 format.
final class HIDLightController: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HIDLightController()

    private let queue = DispatchQueue(label: "com.inputconfig.hidlight")
    /// Last (r, g, b, brightness) we actually sent to the helper. Used
    /// to skip redundant spawns when the requested color matches what
    /// the controller already has - the connect-time retry pattern in
    /// GameControllerService used to spawn the helper 3 times per
    /// controller per plug-in, even when nothing changed.
    private var lastWritten: (r: UInt8, g: UInt8, b: UInt8, br: UInt8)?
    private let lastWrittenLock = NSLock()

    /// Single-flight guard. Only one helper process may run at a time.
    /// Spawning several concurrently makes them fight over seizing the
    /// controller and leaves the light in a stuck/wrong state (the
    /// "breaks after a few window clicks" bug). Rapid requests while a
    /// helper is running are coalesced into `pendingColor`, and only the
    /// most recent one runs when the current helper exits. Accessed only
    /// on `queue`, so no extra lock is needed.
    private var helperRunning = false
    private var pendingColor: (r: UInt8, g: UInt8, b: UInt8, br: UInt8)?

    private init() {}

    /// Set light color with brightness. Brightness: 0=off, 1=dim, 2=bright.
    ///
    /// Pass `force: true` to bypass the dedupe and re-send even if the
    /// color is unchanged. Used when macOS has reset the light behind our
    /// back (e.g. gamecontrolleragentd repaints the player color when the
    /// app loses focus), so we need to re-assert the same color.
    func setLightColor(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8 = 2, force: Bool = false) {
        // Skip the spawn entirely when the requested state matches the
        // last successful write. Saves three subprocess spawns per
        // controller-connect retry burst.
        if !force {
            lastWrittenLock.lock()
            let same = lastWritten.map {
                $0.r == red && $0.g == green && $0.b == blue && $0.br == brightness
            } ?? false
            lastWrittenLock.unlock()
            guard !same else { return }
        } else {
            // Clear the cache so the dedupe doesn't suppress this write.
            lastWrittenLock.lock()
            lastWritten = nil
            lastWrittenLock.unlock()
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            // Single-flight: if a helper is already running, just remember
            // the latest requested color and let the running helper's
            // completion pick it up. This collapses a burst of focus-change
            // re-asserts into at most one follow-up spawn.
            if self.helperRunning {
                self.pendingColor = (red, green, blue, brightness)
                return
            }
            self.helperRunning = true
            self.runHelper(red: red, green: green, blue: blue, brightness: brightness)
        }
    }

    private func runHelper(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8) {
        guard let helperURL = helperPath() else {
            #if DEBUG
            print("[HIDLight] LightHelper not found in bundle")
            #endif
            queue.async { [weak self] in self?.helperFinished(success: false) }
            return
        }

        let task = Process()
        task.executableURL = helperURL
        // "shared" mode: the helper opens the controller non-exclusively
        // and writes the LED report WITHOUT killing gamecontrolleragentd.
        // Confirmed to reach the DualSense LED with no flicker and no
        // controller-input interruption, so we use it for every write -
        // initial sets, preset flashes, and focus-change re-asserts alike.
        // The helper's earlier daemon-kill path has been removed; shared mode
        // and the in-process writer cover every case.
        task.arguments = [String(red), String(green), String(blue), String(brightness), "shared"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        // Async exit notification so we don't block this serial queue
        // for the helper's ~1.2 s lifetime. Previously `waitUntilExit`
        // would head-of-line block every subsequent light change,
        // causing visible color-cycle stutter.
        task.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            let ok = proc.terminationStatus == 0
            if ok {
                self.lastWrittenLock.lock()
                self.lastWritten = (red, green, blue, brightness)
                self.lastWrittenLock.unlock()
            }
            // Release the single-flight slot and run any coalesced
            // follow-up. Hop back onto `queue` so helperRunning /
            // pendingColor stay single-threaded.
            self.queue.async { self.helperFinished(success: ok) }
        }

        do {
            try task.run()
            // Don't `waitUntilExit()`. The serial queue stays free to
            // process the next color change; the terminationHandler
            // releases the single-flight slot when the helper exits.
        } catch {
            #if DEBUG
            print("[HIDLight] Helper launch failed: \(error)")
            #endif
            queue.async { [weak self] in self?.helperFinished(success: false) }
        }
    }

    /// Called on `queue` when a helper process exits (or fails to launch).
    /// Frees the single-flight slot and immediately spawns the most recent
    /// coalesced color, if any.
    private func helperFinished(success: Bool) {
        helperRunning = false
        guard let next = pendingColor else { return }
        pendingColor = nil
        helperRunning = true
        runHelper(red: next.r, green: next.g, blue: next.b, brightness: next.br)
    }

    private func helperPath() -> URL? {
        // App bundle MacOS directory
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("LightHelper") {
            if FileManager.default.isExecutableFile(atPath: bundlePath.path) {
                return bundlePath
            }
        }
        // Resources
        if let resourcePath = Bundle.main.url(forResource: "LightHelper", withExtension: nil) {
            return resourcePath
        }
        // Development fallback
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LightHelper/LightHelper")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }
        return nil
    }
}

/// Writes DualSense / DualShock 4 light-bar colors directly from the app
/// process, in shared (non-seize) mode - no LightHelper subprocess and no
/// gamecontrolleragentd kill. Spawning the helper per frame is far too slow
/// to look smooth, so the high-frequency RGB cycle drives this instead.
///
/// Devices are opened once (shared, coexisting with the system daemon) and
/// the handles reused for fast repeated writes. All IOKit access is
/// serialized on a private queue, so call `open`/`write`/`close` from any
/// thread. `write` lazily opens if needed, so a bare `write` also works.
final class InProcessLightWriter: @unchecked Sendable {
    nonisolated(unsafe) static let shared = InProcessLightWriter()

    private let queue = DispatchQueue(label: "com.inputconfig.inproclight")
    private var devices: [(dev: IOHIDDevice, pid: Int32, isBT: Bool)] = []
    private var sequenceTag: UInt8 = 0
    /// Current solid color to re-assert and the high-rate timer that does it.
    /// Both are touched only on `queue`.
    private var holdColor: (r: UInt8, g: UInt8, b: UInt8)?
    private var holdTimer: DispatchSourceTimer?

    /// Reusable output-report buffers, one per controller report layout.
    /// The hold timer calls writeLocked at 200 Hz; allocating a fresh
    /// [UInt8] on every tick was 200 array allocations per second per
    /// connected controller. These are mutated and sent only on `queue`
    /// (writeLocked is serial), so reuse is race-free. Every write rewrites
    /// the same byte positions, and the zero padding between fields is never
    /// touched, so a reused buffer stays byte-identical to a fresh one.
    private var bufDualSenseUSB = [UInt8](repeating: 0, count: 48)
    private var bufDualSenseBT = [UInt8](repeating: 0, count: 78)
    private var bufDS4USB = [UInt8](repeating: 0, count: 32)
    private var bufDS4BT = [UInt8](repeating: 0, count: 78)

    private static let sonyVID: Int32 = 0x054C
    private static let dualSensePIDs: Set<Int32> = [0x0CE6, 0x0DF2]
    private static let ds4PIDs: Set<Int32> = [0x05C4, 0x09CC]

    private init() {}

    /// Enumerate and open every connected DualSense / DS4 in shared mode.
    /// Safe to call repeatedly; re-opens from scratch each time so it also
    /// serves as a "rescan after hotplug" call.
    func open()  { queue.async { [weak self] in self?.reopenLocked() } }

    /// Close every opened controller. Call when the cycle stops so we don't
    /// hold the devices open indefinitely.
    func close() { queue.async { [weak self] in self?.closeLocked() } }

    /// Write an LED color to every opened controller. RGB + brightness byte
    /// match the LightHelper report layout. Cheap enough to call at 60 Hz.
    func write(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8 = 2) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.devices.isEmpty { self.reopenLocked() }
            // If a hold loop is re-asserting a color at 200 Hz, a bare write
            // would be repainted within milliseconds. Update the held color so
            // this write sticks; callers restore the previous color afterward.
            if self.holdTimer != nil { self.holdColor = (red, green, blue) }
            self.writeLocked(red: red, green: green, blue: blue, brightness: brightness)
        }
    }

    /// Continuously re-assert a solid color at a high rate so macOS 26's
    /// controller daemon, which repaints the LED on focus changes and on a loop
    /// while we're foreground, is overwritten within a few milliseconds, before
    /// it's visible. Runs on this writer's own queue, so it keeps firing at full
    /// rate even when the app is backgrounded and the main run loop is throttled.
    /// Call again to change the held color; call `stopHold()` to end it.
    func startHold(red: UInt8, green: UInt8, blue: UInt8) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.holdColor = (red, green, blue)
            if self.devices.isEmpty { self.reopenLocked() }
            self.writeLocked(red: red, green: green, blue: blue, brightness: 2)  // immediate
            guard self.holdTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            // 60 Hz is one re-assert per display frame - visually identical
            // to the old 5 ms cadence at a third of the USB/BT bus traffic
            // and CPU (this loop runs the whole time a preset holds a color).
            t.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in
                guard let self = self, let c = self.holdColor else { return }
                self.writeLocked(red: c.r, green: c.g, blue: c.b, brightness: 2)
            }
            self.holdTimer = t
            t.resume()
        }
    }

    func stopHold() {
        queue.async { [weak self] in
            self?.holdTimer?.cancel()
            self?.holdTimer = nil
            self?.holdColor = nil
        }
    }

    // MARK: - queue-only internals

    private func reopenLocked() {
        closeLocked()
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDVendorIDKey as String] = Self.sonyVID
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            guard let pidRef = IORegistryEntryCreateCFProperty(entry, kIOHIDProductIDKey as CFString, kCFAllocatorDefault, 0) else { continue }
            // Read the ProductID defensively. IORegistry properties are
            // device-reported, so a forced cast would crash the app if any
            // Sony-VID device ever reported this as something other than a
            // number. This mirrors the safe as? handling used for the
            // transport key just below.
            guard let pid = (pidRef.takeUnretainedValue() as? NSNumber)?.int32Value else { continue }
            guard Self.dualSensePIDs.contains(pid) || Self.ds4PIDs.contains(pid) else { continue }
            guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, entry) else { continue }
            // Shared (non-exclusive) open: coexists with gamecontrolleragentd.
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            var isBT = false
            if let tRef = IORegistryEntryCreateCFProperty(entry, kIOHIDTransportKey as CFString, kCFAllocatorDefault, 0) {
                isBT = ((tRef.takeUnretainedValue() as? String) ?? "").lowercased().contains("bluetooth")
            }
            devices.append((dev, pid, isBT))
        }
    }

    private func closeLocked() {
        for d in devices { IOHIDDeviceClose(d.dev, 0) }
        devices.removeAll()
    }

    private func writeLocked(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8) {
        for d in devices {
            let isDS = Self.dualSensePIDs.contains(d.pid)
            if isDS && !d.isBT {
                bufDualSenseUSB[0] = 0x02; bufDualSenseUSB[2] = 0x04; bufDualSenseUSB[39] = 0x06; bufDualSenseUSB[42] = 0x02
                bufDualSenseUSB[43] = brightness; bufDualSenseUSB[45] = red; bufDualSenseUSB[46] = green; bufDualSenseUSB[47] = blue
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x02, bufDualSenseUSB, bufDualSenseUSB.count)
            } else if isDS && d.isBT {
                // 78-byte BT report: [0]=0x31, [1]=sequence<<4, [2]=0x10 tag,
                // then the SAME payload as USB starting at [3]. The old code
                // omitted the 0x10 tag byte, which shifted every field by one
                // and put the CRC at the wrong offset - the controller
                // silently discarded every packet, which is why the light
                // never changed over Bluetooth. Layout verified live: this
                // exact report turned the user's Edge blue.
                bufDualSenseBT[0] = 0x31
                sequenceTag = (sequenceTag &+ 1) & 0x0F
                bufDualSenseBT[1] = sequenceTag << 4
                bufDualSenseBT[2] = 0x10
                bufDualSenseBT[4] = 0x04                       // valid_flag1: lightbar control
                bufDualSenseBT[41] = 0x02                      // valid_flag2: lightbar setup
                bufDualSenseBT[44] = 0x02                      // lightbar_setup: light on
                bufDualSenseBT[45] = brightness
                bufDualSenseBT[47] = red; bufDualSenseBT[48] = green; bufDualSenseBT[49] = blue
                let crc = Self.crc32(prefix: [0xA2], buffer: bufDualSenseBT, range: 0..<74)
                bufDualSenseBT[74] = UInt8(crc & 0xFF); bufDualSenseBT[75] = UInt8((crc >> 8) & 0xFF)
                bufDualSenseBT[76] = UInt8((crc >> 16) & 0xFF); bufDualSenseBT[77] = UInt8((crc >> 24) & 0xFF)
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x31, bufDualSenseBT, bufDualSenseBT.count)
            } else if Self.ds4PIDs.contains(d.pid) && !d.isBT {
                bufDS4USB[0] = 0x05; bufDS4USB[1] = 0x07; bufDS4USB[6] = red; bufDS4USB[7] = green; bufDS4USB[8] = blue
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x05, bufDS4USB, bufDS4USB.count)
            } else if Self.ds4PIDs.contains(d.pid) && d.isBT {
                // 78-byte DS4 BT report per DS4Windows / hid-sony: header
                // [1]=0xC0 (HID+CRC), [2]=0xA0, enable flags [3]=0xF7,
                // [4]=0x04, RGB at [8..10], CRC over [0..73] at [74..77].
                // Same shifted-fields + misplaced-CRC bug as the DualSense
                // BT path; fixed from documentation (no DS4 on hand).
                bufDS4BT[0] = 0x11; bufDS4BT[1] = 0xC0; bufDS4BT[2] = 0xA0; bufDS4BT[3] = 0xF7; bufDS4BT[4] = 0x04
                bufDS4BT[8] = red; bufDS4BT[9] = green; bufDS4BT[10] = blue
                let crc = Self.crc32(prefix: [0xA2], buffer: bufDS4BT, range: 0..<74)
                bufDS4BT[74] = UInt8(crc & 0xFF); bufDS4BT[75] = UInt8((crc >> 8) & 0xFF)
                bufDS4BT[76] = UInt8((crc >> 16) & 0xFF); bufDS4BT[77] = UInt8((crc >> 24) & 0xFF)
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x11, bufDS4BT, bufDS4BT.count)
            }
        }
    }

    /// Precomputed CRC32 table - the old bit-serial loop did ~600 shifts per
    /// packet on every hold tick.
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1 != 0) ? (c >> 1) ^ 0xEDB88320 : c >> 1 }
        return c
    }

    /// CRC over `prefix` followed by `buffer[range]`, with zero heap
    /// allocations (the old call site concatenated two fresh arrays per tick,
    /// ~400 allocs/second per Bluetooth controller while holding a color).
    private static func crc32(prefix: [UInt8], buffer: [UInt8], range: Range<Int>) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in prefix {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        for i in range {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(buffer[i])) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }
}
