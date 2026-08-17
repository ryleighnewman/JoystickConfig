import Foundation
import IOKit
import IOKit.hid

/// Reads DualSense / DualSense Edge controllers directly via IOKit HID
/// alongside Apple's GameController framework, parsing the Edge's
/// exclusive buttons (paddles, FN, mute) that Apple's GC framework
/// does not expose. Standard buttons keep flowing through GCController;
/// the Edge extras come from here and are merged into the slot's
/// ControllerState by GameControllerService.
///
/// Follows the same pattern as `SteamControllerService`: a plain
/// `final class` declared `@unchecked Sendable`, with all mutable
/// state guarded by a single `NSLock`. Avoids the @MainActor /
/// nonisolated mismatch that surfaces under Swift 6 strict
/// concurrency when a C HID callback tries to reach back into an
/// @MainActor singleton.
final class DualSenseSupplementService: @unchecked Sendable {

    static let shared = DualSenseSupplementService()

    /// Sony VID + the two DualSense PIDs we care about (base + Edge).
    private static let vendorID: Int32 = 0x054C
    private static let dualSensePIDs: Set<Int32> = [0x0CE6, 0x0DF2]

    /// Logical button slots the supplement publishes. These match the
    /// indices `cacheExtraButtons` reserves so the binding pipeline
    /// can pick them up without remapping.
    ///   15 = Microphone / Mute
    ///   16 = Left Paddle
    ///   17 = Right Paddle
    ///   20 = FN1 (left function)
    ///   21 = FN2 (right function)
    enum SupplementButton: Int {
        case mute = 15
        case leftPaddle = 16
        case rightPaddle = 17
        case leftFunction = 20
        case rightFunction = 21
    }

    /// Toggle that controls whether we NSLog raw report bytes for
    /// debugging. Off in shipping builds. The byte offsets for the
    /// buttons we DO support (PS, Mute) are already locked in below.
    nonisolated(unsafe) static var logRawBytes: Bool = false

    // MARK: - State (lock-guarded)

    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var liveDevices: [UInt64: IOHIDDevice] = [:]
    private var reportBuffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private var supplementalState: [UInt64: [Int: Float]] = [:]
    private var lastLoggedByte11: [UInt64: UInt8] = [:]
    private var reportCounter: [UInt64: Int] = [:]
    /// Timestamp of the last streamed (callback-delivered) input report per
    /// device. The poll timer stands down while the stream is alive.
    private var lastStreamAt: [UInt64: TimeInterval] = [:]
    /// GET_REPORT poll timer, running while any DualSense is attached.
    private var pollTimer: DispatchSourceTimer?
    /// Location-report keys whose first poll result has been logged.
    private var pollHealthLogged: Set<String> = []
    private var pollTickCount: Int = 0
    private let pollQueue = DispatchQueue(label: "com.inputconfig.dsedgepoll")
    /// Last-seen bytes 8-49 EXCLUDING known counter slots so we log
    /// any change that could be the Edge's paddle/FN bits without
    /// also logging every counter increment 250×/sec.
    private var lastSignificantBytes: [UInt64: [UInt8]] = [:]
    private let reportBufferSize = 78

    private init() {}

    // MARK: - Lifecycle

    /// Open the DualSense raw HID device in-process, non-seize, alongside
    /// gamecontrollerd. This is the only route to the Edge's extra buttons
    /// on modern macOS: Apple's GameController profile for the DualSense
    /// Edge exposes NO paddle / FN / mute buttons (verified against the
    /// live profile dump - standard buttons + touchpad + Home only, and
    /// the leftPaddleButton-style KVC keys are absent).
    ///
    /// Both transports deliver input reports to this in-process reader,
    /// sandbox included - verified live over Bluetooth (0x31 reports,
    /// FN presses decoded) and historically over USB (PS/mute). A BT
    /// connection can occasionally wedge into delivering no reports
    /// (power-cycling the controller clears it); the GET_REPORT poll
    /// below covers that case, so the extras keep working regardless.
    ///
    /// The old conflict that parked this service (starving TouchpadHelper's
    /// touchpad feed) is moot: on macOS 14+ TouchpadService never launches
    /// the helper (GameController's touchpadPrimary bridge is the touch
    /// source) and the app's deployment target is 14.0.
    func start() {
        let enableLegacyOpen = true
        NSLog("[DualSenseSupplement] start() - opening DualSense raw HID (USB extras reader)")

        if enableLegacyOpen {
            lock.lock()
            let alreadyStarted = (manager != nil)
            lock.unlock()
            guard !alreadyStarted else { return }

            let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                         IOOptionBits(kIOHIDOptionsTypeNone))
            var matches: [[String: Any]] = []
            for pid in Self.dualSensePIDs {
                matches.append([
                    kIOHIDVendorIDKey as String: Self.vendorID,
                    kIOHIDProductIDKey as String: pid
                ])
            }
            IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
            IOHIDManagerScheduleWithRunLoop(mgr,
                                            CFRunLoopGetMain(),
                                            CFRunLoopMode.defaultMode.rawValue)
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
                guard let context else { return }
                let svc = Unmanaged<DualSenseSupplementService>.fromOpaque(context).takeUnretainedValue()
                svc.handleAttached(device)
            }, selfPtr)
            IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
                guard let context else { return }
                let svc = Unmanaged<DualSenseSupplementService>.fromOpaque(context).takeUnretainedValue()
                svc.handleDetached(device)
            }, selfPtr)
            IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            lock.lock()
            manager = mgr
            lock.unlock()
        }

        NSLog("[DualSenseSupplement] manager opened, watching Sony VID 0x054C")
    }

    func stop() {
        lock.lock()
        let devices = liveDevices
        let buffers = reportBuffers
        let mgr = manager
        liveDevices.removeAll()
        reportBuffers.removeAll()
        supplementalState.removeAll()
        lastLoggedByte11.removeAll()
        lastStreamAt.removeAll()
        let poll = pollTimer
        pollTimer = nil
        manager = nil
        lock.unlock()
        poll?.cancel()

        for (_, device) in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for (_, buf) in buffers { buf.deallocate() }
        if let mgr {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr,
                                              CFRunLoopGetMain(),
                                              CFRunLoopMode.defaultMode.rawValue)
        }
    }

    // MARK: - Device lifecycle (called from IOKit callbacks - any thread)

    private func handleAttached(_ device: IOHIDDevice) {
        guard let locRef = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else { return }
        let location = locRef.uint64Value

        lock.lock()
        let already = (liveDevices[location] != nil)
        lock.unlock()
        guard !already else { return }

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            NSLog("[DualSenseSupplement] open failed for location 0x%llX: %d", location, openResult)
            return
        }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        buf.initialize(repeating: 0, count: reportBufferSize)

        lock.lock()
        liveDevices[location] = device
        reportBuffers[location] = buf
        supplementalState[location] = [:]
        lock.unlock()

        // Use the location ID directly as the callback context. Safe
        // because the ID is just a UInt64 packed into the pointer
        // bits; no object lifetime to manage.
        let locationCookie = UnsafeMutableRawPointer(bitPattern: UInt(location))
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buf,
            reportBufferSize,
            dualSenseSupplementCallback,
            locationCookie
        )
        IOHIDDeviceScheduleWithRunLoop(device,
                                       CFRunLoopGetMain(),
                                       CFRunLoopMode.defaultMode.rawValue)

        let productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        NSLog("[DualSenseSupplement] attached %@ (loc=0x%llX)", productName, location)
        startPollingIfNeeded()
        // Note: we previously tried sending feature / output reports
        // to "unlock" the DualSense Edge's paddle/FN bits in the
        // input report. Empirically verified that no candidate
        // command (0x80, 0x09, etc.) changed the report layout - the
        // Edge keeps internally remapping paddles to other buttons
        // regardless. Sony's actual extended-profile unlock is
        // undocumented. Leaving this comment as a breadcrumb for
        // future investigation.
    }

    private func handleDetached(_ device: IOHIDDevice) {
        guard let locRef = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else { return }
        let location = locRef.uint64Value

        lock.lock()
        let dev = liveDevices.removeValue(forKey: location)
        let buf = reportBuffers.removeValue(forKey: location)
        supplementalState.removeValue(forKey: location)
        lastLoggedByte11.removeValue(forKey: location)
        lock.unlock()

        if let dev {
            IOHIDDeviceUnscheduleFromRunLoop(dev,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let buf { buf.deallocate() }
        lock.lock()
        lastStreamAt.removeValue(forKey: location)
        lock.unlock()
        stopPollingIfIdle()
        NSLog("[DualSenseSupplement] detached (loc=0x%llX)", location)
    }

    // MARK: - Report dispatch (called from C callback)

    /// Parse one input report. DualSense base USB report (ID 0x01) layout:
    ///   byte 0:  report ID
    ///   bytes 1-6: sticks + triggers
    ///   byte 7:  counter
    ///   byte 8:  D-pad + face buttons
    ///   byte 9:  shoulders + Create + Options + L3 + R3
    ///   byte 10: PS, Touchpad, Mute (bit 0=PS, bit 1=touchpad, bit 2=mute)
    /// The DualSense Edge extends the report with paddle/FN bits; we
    /// log byte-11 changes when `logRawBytes` is on so the user can
    /// identify the correct offsets empirically.
    func handleReport(locationID: UInt64,
                      reportPointer: UnsafePointer<UInt8>,
                      length: Int) {
        guard length >= 11 else { return }

        // Mark the stream alive so the GET_REPORT poll stands down for
        // this device (streamed reports are lower-latency than polling).
        lock.lock()
        let firstStream = (lastStreamAt[locationID] == nil)
        lastStreamAt[locationID] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        if firstStream {
            NSLog("[DualSenseSupplement] stream ALIVE (loc=0x%llX) first report id=0x%02X len=%d",
                  locationID, reportPointer[0], length)
        }

        // Diagnostics. Capture button-candidate bytes 8-15 and
        // bytes 30-49 (where community-documented Edge profile bytes
        // tend to live). EXPLICITLY EXCLUDE:
        //   byte 7  - report counter
        //   byte 12 - secondary counter
        //   bytes 16-29 - motion sensor (gyro/accel/touchpad fingers)
        //                 change every report and would otherwise
        //                 drive the change detector to fire 250x/sec.
        if Self.logRawBytes && length >= 50 {
            // Bytes that are KNOWN counters / sensors and must be
            // excluded from the change detector. Build current state
            // from button-candidate bytes only.
            //   byte 8  = D-pad + face (standard)
            //   byte 9  = shoulders + menu (standard)
            //   byte 10 = PS / touchpad / mute (standard)
            //   byte 11 = candidate for Edge extras
            //   bytes 32-49 = deeper area where some firmwares
            //                 expose Edge profile bits
            // Excluded: 7 (counter), 12 (counter), 13-15 (timer),
            //           16-29 (motion sensors), 30-31 (counters).
            var current: [UInt8] = []
            for i in 8...11 { current.append(reportPointer[i]) }
            for i in 32..<min(50, length) { current.append(reportPointer[i]) }

            lock.lock()
            let prev = lastSignificantBytes[locationID]
            let changed = prev != current
            if changed { lastSignificantBytes[locationID] = current }
            reportCounter[locationID, default: 0] += 1
            let count = reportCounter[locationID] ?? 0
            let isHeartbeat = (count % 500) == 1   // every ~2s at 250 Hz
            lock.unlock()

            if changed || isHeartbeat {
                var winA: [String] = []
                for i in 8...11 { winA.append(String(format: "%02X", reportPointer[i])) }
                var winB: [String] = []
                for i in 32..<min(50, length) { winB.append(String(format: "%02X", reportPointer[i])) }
                let tag = changed ? "CHANGE" : "HEARTBEAT"
                NSLog("[DualSenseSupplement] %@ b[8..11]= %@ | b[32..%d]= %@",
                      tag, winA.joined(separator: " "), min(50, length), winB.joined(separator: " "))
            }
        }

        // buttons[2] of the report payload carries PS/Home (bit 0),
        // touchpad press (bit 1), Mute (bit 2), and on the DualSense
        // Edge the four extra hardware buttons in the high nibble.
        // The IOHID input buffer includes the report ID at [0], so:
        //   USB report 0x01: payload starts at [1], buttons[2] = [10].
        //     (PS at [10] bit 0 was verified over 16+ press/release
        //     transitions in a live USB stream.)
        //   BT report 0x31: ID at [0], sequence tag at [1], payload at
        //     [2], buttons[2] = [11]. Verified live over Bluetooth:
        //     an Edge FN press flips [11] bit 4 while the sticks sit at
        //     [2..5] and the d-pad hat idles as 0x08 at [9]. BT reports
        //     DO reach this second non-seize reader alongside the
        //     system daemon; a connection can wedge into delivering
        //     nothing (power-cycling the controller clears it), which
        //     is where the old "Bluetooth gives zero reports" belief
        //     came from.
        let b2: UInt8
        if reportPointer[0] == 0x01 {
            b2 = reportPointer[10]
        } else if reportPointer[0] == 0x31 && length >= 12 {
            b2 = reportPointer[11]
        } else {
            return
        }
        applyButtons2(b2, locationID: locationID)
    }

    /// Sentinel location key for the TouchpadHelper-fed state, so it can
    /// coexist in `supplementalState` with any direct in-process reads.
    private static let helperLocationKey: UInt64 = .max

    /// Entry point for the helper's "B" lines (via TouchpadService). Over
    /// Bluetooth the app's own HID open receives no input reports while its
    /// GameController session is active, but the external helper process
    /// does - so this is how the Edge extras arrive on BT.
    func ingestHelperButtons2(_ b2: UInt8) {
        applyButtons2(b2, locationID: Self.helperLocationKey)
    }

    /// Decode one buttons[2] byte into the supplemental button snapshot.
    private func applyButtons2(_ b2: UInt8, locationID: UInt64) {
        let psDown   = (b2 & 0x01) != 0
        let muteDown = (b2 & 0x04) != 0
        // DualSense Edge extras, per the Linux hid-playstation driver
        // and DS4Windows (same byte as PS/mute, high nibble):
        //   bit 4 = left function (FN), bit 5 = right function (FN),
        //   bit 6 = left paddle,        bit 7 = right paddle.
        let fnLeft   = (b2 & 0x10) != 0
        let fnRight  = (b2 & 0x20) != 0
        let lPaddle  = (b2 & 0x40) != 0
        let rPaddle  = (b2 & 0x80) != 0

        var snapshot: [Int: Float] = [:]
        // Index 10 = Home/PS - merging here lets us fire the binding
        // even when Apple's GameController framework swallows the PS
        // event for system-level Game Mode handling on macOS 26+.
        snapshot[10]                                       = psDown   ? 1.0 : 0.0
        snapshot[SupplementButton.mute.rawValue]           = muteDown ? 1.0 : 0.0
        snapshot[SupplementButton.leftFunction.rawValue]   = fnLeft   ? 1.0 : 0.0
        snapshot[SupplementButton.rightFunction.rawValue]  = fnRight  ? 1.0 : 0.0
        snapshot[SupplementButton.leftPaddle.rawValue]     = lPaddle  ? 1.0 : 0.0
        snapshot[SupplementButton.rightPaddle.rawValue]    = rPaddle  ? 1.0 : 0.0

        lock.lock()
        let changed = (supplementalState[locationID] != snapshot)
        supplementalState[locationID] = snapshot
        lock.unlock()

        // Change-gated diagnostic. Fires only on press/release edges of
        // the supplement buttons (a handful of events per session), so
        // it stays silent during the 130-250 Hz report stream while
        // giving `log stream` visibility into exactly which raw bits
        // the controller sends - the tool that finally mapped the Edge.
        if changed && b2 != 0 {
            NSLog("[DualSenseSupplement] buttons2=0x%02X ps=%d mute=%d fnL=%d fnR=%d padL=%d padR=%d",
                  b2, psDown ? 1 : 0, muteDown ? 1 : 0, fnLeft ? 1 : 0,
                  fnRight ? 1 : 0, lPaddle ? 1 : 0, rPaddle ? 1 : 0)
        }
    }

    // MARK: - GET_REPORT polling (the Bluetooth path)

    /// Poll the current input report with a synchronous GET_REPORT device
    /// request. Over Bluetooth the sandbox delivers NO streamed input
    /// reports to this app (or to its sandboxed helper) - but device
    /// requests go through: SetReport drives the light bar over BT today,
    /// and GetReport was verified live to return fresh 78-byte 0x31
    /// snapshots (the embedded counter advances between polls). 30 Hz gives
    /// worst-case ~33 ms latency on paddle presses, in line with a 30 Hz
    /// UI poll frame. The timer stands down per-device whenever streamed
    /// reports are flowing (USB), so the poll only pays for itself when it
    /// is the only source.
    private func startPollingIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard pollTimer == nil, !liveDevices.isEmpty else { return }
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now() + .milliseconds(33),
                   repeating: .milliseconds(33),
                   leeway: .milliseconds(8))
        t.setEventHandler { [weak self] in self?.pollTick() }
        pollTimer = t
        t.resume()
        NSLog("[DualSenseSupplement] GET_REPORT poll started (30 Hz)")
    }

    private func stopPollingIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard liveDevices.isEmpty, let t = pollTimer else { return }
        pollTimer = nil
        t.cancel()
        NSLog("[DualSenseSupplement] GET_REPORT poll stopped")
    }

    private func pollTick() {
        lock.lock()
        let targets = liveDevices.filter { (loc, _) in
            // Stand down while streamed reports are arriving for this device.
            (CFAbsoluteTimeGetCurrent() - (lastStreamAt[loc] ?? 0)) > 1.0
        }
        pollTickCount += 1
        let tick = pollTickCount
        let liveCount = liveDevices.count
        let streamStamps = lastStreamAt.count
        lock.unlock()
        if tick == 1 || (Self.logRawBytes && tick % 150 == 0) {
            NSLog("[DualSenseSupplement] tick=%d live=%d targets=%d streamStamped=%d",
                  tick, liveCount, targets.count, streamStamps)
        }
        guard !targets.isEmpty else { return }

        var buf = [UInt8](repeating: 0, count: 96)
        for (location, device) in targets {
            // Try the full BT report first, then the USB/simple report.
            for rid: CFIndex in [0x31, 0x01] {
                var len: CFIndex = buf.count
                let gr = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, rid, &buf, &len)
                // One-shot health line so a silent poll is distinguishable
                // from a working poll with no buttons pressed.
                lock.lock()
                let firstForKey = !pollHealthLogged.contains("\(location)-\(rid)")
                if firstForKey { pollHealthLogged.insert("\(location)-\(rid)") }
                lock.unlock()
                if firstForKey {
                    NSLog("[DualSenseSupplement] poll id=0x%02lX -> %@ len=%ld", rid,
                          gr == kIOReturnSuccess ? "ok" : String(format: "0x%08X", UInt32(bitPattern: gr)), len)
                }
                guard gr == kIOReturnSuccess, len > 11 else { continue }
                // GetReport buffers carry the same layout as the streamed
                // callback buffer: report ID at [0].
                let b2: UInt8
                if buf[0] == 0x31 {
                    b2 = buf[11]
                } else if buf[0] == 0x01 && len > 10 {
                    b2 = buf[10]
                } else {
                    continue
                }
                applyButtons2(b2, locationID: location)
                break
            }
        }
    }

    // MARK: - Lookup helpers

    /// Returns the union of supplemental button states across all
    /// attached DualSenses. Acceptable when there's only one (the
    /// common case).
    func anySupplementalButtons() -> [Int: Float] {
        // Build the union directly under the lock instead of first copying the
        // entire per-device dictionary. This is called for every DualSense slot
        // on every poll frame (120 Hz engine + 30 Hz UI), so the extra
        // whole-dictionary copy was pure per-frame allocation churn. The state
        // is tiny (a couple of entries per device) so holding the lock for the
        // merge is negligible.
        lock.lock()
        defer { lock.unlock() }
        var merged: [Int: Float] = [:]
        for (_, buttons) in supplementalState {
            for (idx, val) in buttons where val > 0.5 {
                merged[idx] = val
            }
        }
        return merged
    }
}

// MARK: - C callback bridge

private func dualSenseSupplementCallback(context: UnsafeMutableRawPointer?,
                                         result: IOReturn,
                                         sender: UnsafeMutableRawPointer?,
                                         type: IOHIDReportType,
                                         reportID: UInt32,
                                         report: UnsafeMutablePointer<UInt8>,
                                         reportLength: CFIndex) {
    guard result == kIOReturnSuccess, let context else { return }
    let location = UInt64(UInt(bitPattern: context))
    DualSenseSupplementService.shared.handleReport(
        locationID: location,
        reportPointer: report,
        length: Int(reportLength)
    )
}
