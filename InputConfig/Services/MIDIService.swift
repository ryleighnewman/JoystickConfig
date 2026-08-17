import Foundation
import CoreMIDI

/// Sends MIDI messages out of a virtual MIDI source named "InputConfig".
///
/// Any DAW or music app on the Mac that supports external MIDI input (Logic
/// Pro, Ableton Live, GarageBand, MainStage, Bitwig, FL Studio for Mac, etc.)
/// will see "InputConfig" as an available MIDI source. The user connects
/// to it in the DAW's MIDI settings and our controller becomes a MIDI device.
///
/// Implementation notes:
///   - Uses MIDIClientCreate + MIDISourceCreate to expose the virtual port.
///   - No sandbox entitlement is needed for CoreMIDI virtual sources.
///   - Tracks active notes so the engine can release them cleanly when the
///     binding fires note-off.
///   - Pitch bend is sent as a 14-bit value (0 to 16383, centered at 8192).
///   - Variable axes get scaled to the appropriate 0..127 or 0..16383 range
///     by the MappingEngine before it calls into this service.
final class MIDIService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = MIDIService()

    private let queue = DispatchQueue(label: "com.inputconfig.midi")
    private var client: MIDIClientRef = 0
    private var virtualSource: MIDIEndpointRef = 0
    private var isSetup = false

    /// Active notes per channel keyed by note number. releaseAllNotes() uses
    /// this to silence every tracked note when the engine stops or a preset
    /// deactivates. Per-note sendNoteOff silences only the note it is handed (it
    /// does not consult this set), so a binding that changes its note value
    /// mid-press should rely on releaseAllNotes, not a paired note-off, to
    /// avoid leaving the previous note stuck on.
    private var activeNotes: [Int: Set<Int>] = [:] // channel -> notes
    private let activeNotesLock = NSLock()

    /// Display name of the virtual MIDI port. Apps will see this in their
    /// MIDI source list.
    static let portName = "InputConfig"

    private init() {
        // Pre-allocate the activeNotes dict for every possible MIDI
        // channel so note-on doesn't pay a "create empty Set + insert
        // + write back to dict" round trip on every press. With 16
        // pre-allocated Sets, the hot path becomes a single
        // `insert(note)` on an existing Set reference.
        for ch in 0..<16 {
            activeNotes[ch] = Set<Int>()
        }
        setup()
    }

    /// Whether the virtual MIDI port was created successfully. If false the
    /// rest of the methods become no-ops.
    var isReady: Bool { isSetup }

    // MARK: - Setup

    private func setup() {
        let clientName = "InputConfig" as CFString
        let status = MIDIClientCreateWithBlock(clientName, &client) { _ in
            // CoreMIDI notifications come through here (devices added/removed).
            // We don't need to act on them for outbound-only use.
        }
        guard status == noErr else {
            return
        }

        let portName = Self.portName as CFString
        let srcStatus = MIDISourceCreate(client, portName, &virtualSource)
        guard srcStatus == noErr else {
            return
        }

        // Make the virtual source persist across sessions so DAWs can reconnect
        // automatically. Earlier this derived the id from String.hashValue,
        // which since Swift 4.2 is randomly seeded PER PROCESS, so the id
        // changed every launch and DAWs lost their saved connection; abs() on
        // it could also trap on Int.min. Generate a stable random id once and
        // persist it.
        let uniqueIDKey = "InputConfig.midiSourceUniqueID"
        let uniqueID: Int32
        if let saved = UserDefaults.standard.object(forKey: uniqueIDKey) as? Int {
            uniqueID = Int32(truncatingIfNeeded: saved)
        } else {
            let generated = Int32.random(in: 1...Int32.max)
            UserDefaults.standard.set(Int(generated), forKey: uniqueIDKey)
            uniqueID = generated
        }
        MIDIObjectSetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, uniqueID)

        isSetup = true
    }

    // MARK: - Sending

    /// Send a Note On.
    func sendNoteOn(note: Int, velocity: Int, channel: Int) {
        guard isSetup else { return }
        let safeNote = clamp(note, 0, 127)
        let safeVel = clamp(velocity, 1, 127) // 0 velocity is interpreted as note-off
        let safeCh = clamp(channel - 1, 0, 15)

        queue.async { [self] in
            send(bytes: [0x90 | UInt8(safeCh), UInt8(safeNote), UInt8(safeVel)])
            track(note: safeNote, channel: safeCh, on: true)
        }
    }

    /// Send a Note Off.
    func sendNoteOff(note: Int, channel: Int) {
        guard isSetup else { return }
        let safeNote = clamp(note, 0, 127)
        let safeCh = clamp(channel - 1, 0, 15)
        queue.async { [self] in
            send(bytes: [0x80 | UInt8(safeCh), UInt8(safeNote), 0])
            track(note: safeNote, channel: safeCh, on: false)
        }
    }

    /// Release every note we have tracked as active. Called by MappingEngine
    /// when the engine stops or a preset is deactivated, so we never leave
    /// stuck notes hanging in the DAW.
    func releaseAllNotes() {
        guard isSetup else { return }
        queue.async { [self] in
            activeNotesLock.lock()
            let snapshot = activeNotes
            // Reset the per-channel sets in place (pre-populated with
            // empty Set<Int> in init) rather than removing keys, so
            // future note-on calls don't have to re-allocate the
            // per-channel storage.
            for ch in activeNotes.keys {
                activeNotes[ch]?.removeAll(keepingCapacity: true)
            }
            activeNotesLock.unlock()

            // Per-note NoteOff for everything we know about.
            for (channel, notes) in snapshot {
                for note in notes {
                    send(bytes: [0x80 | UInt8(channel), UInt8(note), 0])
                }
            }

            // Belt-and-suspenders: also blast CC 123 (All Notes Off)
            // on every channel. Catches the case where the DAW lost
            // a NoteOn (dropped packet, clock skew) and would
            // otherwise hold a stuck note forever after the engine
            // stops. CC 123 is the standard MIDI panic gesture.
            for channel in 0..<16 {
                send(bytes: [0xB0 | UInt8(channel), 123, 0])
            }

            // Also reset continuous controllers and re-center pitch bend, so a
            // CC or pitch-bend binding that was mid-send doesn't leave the DAW
            // with a stuck mod wheel or a detuned pitch after the engine stops.
            for channel in 0..<16 {
                send(bytes: [0xB0 | UInt8(channel), 121, 0])     // Reset All Controllers
                send(bytes: [0xE0 | UInt8(channel), 0x00, 0x40]) // Pitch bend center
            }
            // The CC reset above returns the DAW's controllers to default, so
            // drop the dedup caches; the next CC / pitch-bend send must reach
            // the DAW even if its value matches what we last sent before stop.
            lastSentCC.removeAll(keepingCapacity: true)
            lastSentPitchBend.removeAll(keepingCapacity: true)
        }
    }

    /// Last quantized value sent per (channel, controller), used to drop
    /// redundant identical CC packets that a variable axis would otherwise
    /// emit every poll frame. Only touched on `queue`, so it needs no lock.
    private var lastSentCC: [Int: Int] = [:]

    /// Last pitch-bend value sent per channel, to drop redundant identical
    /// pitch-bend packets a held stick would otherwise emit every frame. Only
    /// touched on `queue`.
    private var lastSentPitchBend: [Int: Int] = [:]

    /// Send a Control Change. `value` is 0-127.
    func sendCC(controller: Int, value: Int, channel: Int) {
        guard isSetup else { return }
        let safeCC = clamp(controller, 0, 127)
        let safeVal = clamp(value, 0, 127)
        let safeCh = clamp(channel - 1, 0, 15)

        queue.async { [self] in
            // Skip redundant identical CC packets: a variable axis bound to a
            // CC can fire the same 0-127 value every poll frame (up to ~120/s),
            // flooding the DAW. Only send when the value actually changed.
            let key = (safeCh << 8) | safeCC
            if lastSentCC[key] == safeVal { return }
            lastSentCC[key] = safeVal
            send(bytes: [0xB0 | UInt8(safeCh), UInt8(safeCC), UInt8(safeVal)])
        }
    }

    /// Send Pitch Bend. `value` is 0-16383, centered at 8192.
    func sendPitchBend(value: Int, channel: Int) {
        guard isSetup else { return }
        let safeVal = clamp(value, 0, 16383)
        let safeCh = clamp(channel - 1, 0, 15)
        let lsb = UInt8(safeVal & 0x7F)
        let msb = UInt8((safeVal >> 7) & 0x7F)
        queue.async { [self] in
            // Skip redundant identical pitch-bend packets: a held stick would
            // otherwise flood the DAW every poll frame.
            if lastSentPitchBend[safeCh] == safeVal { return }
            lastSentPitchBend[safeCh] = safeVal
            send(bytes: [0xE0 | UInt8(safeCh), lsb, msb])
        }
    }

    /// Send a Program Change. The receiving instrument switches to the
    /// numbered patch (sound) when this arrives. `program` is 0-127.
    func sendProgramChange(program: Int, channel: Int) {
        guard isSetup else { return }
        let safeProg = clamp(program, 0, 127)
        let safeCh = clamp(channel - 1, 0, 15)
        queue.async { [self] in
            send(bytes: [0xC0 | UInt8(safeCh), UInt8(safeProg)])
        }
    }

    /// Send a real-time transport message. These are single-byte system
    /// messages with no channel - DAWs use them to control playback.
    /// 0xFA = Start, 0xFB = Continue, 0xFC = Stop.
    func sendTransport(_ transport: MIDITransport) {
        guard isSetup else { return }
        queue.async { [self] in
            send(bytes: [transport.statusByte])
        }
    }

    /// Send a single MIDI Timing Clock tick (0xF8). Twenty-four of these per
    /// quarter note are required to sync hardware sequencers and similar.
    /// Most users will not call this directly; included for completeness so
    /// future features can drive clock from a configurable rate.
    func sendClockTick() {
        guard isSetup else { return }
        queue.async { [self] in
            send(bytes: [0xF8])
        }
    }

    // MARK: - Internal Sending

    private func send(bytes: [UInt8]) {
        guard isSetup else { return }
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        let now = MIDITimeStamp(0)

        bytes.withUnsafeBufferPointer { buf in
            _ = MIDIPacketListAdd(&packetList,
                                  MemoryLayout<MIDIPacketList>.size,
                                  packet,
                                  now,
                                  bytes.count,
                                  buf.baseAddress!)
        }
        MIDIReceived(virtualSource, &packetList)
    }

    private func track(note: Int, channel: Int, on: Bool) {
        activeNotesLock.lock()
        defer { activeNotesLock.unlock() }
        // `activeNotes` is pre-populated in init for channels 0..15, so
        // the dict subscript always hits an existing key. Mutate the
        // stored Set in place via the subscript-with-default pattern,
        // which avoids the read-copy-write dance the previous version
        // did (allocated a new Set on every note-on).
        if on {
            activeNotes[channel, default: Set<Int>()].insert(note)
        } else {
            activeNotes[channel]?.remove(note)
        }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        return min(max(v, lo), hi)
    }

    // MARK: - Helpers

    /// Convert a MIDI note number into a human-readable label like "C4".
    /// MIDI note 60 is middle C in scientific pitch notation (C4).
    static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let safeNote = max(0, min(127, note))
        let octave = (safeNote / 12) - 1
        let name = names[safeNote % 12]
        return "\(name)\(octave)"
    }

    /// Common CC numbers with human-readable names. Used in the binding
    /// editor's CC picker so users can find familiar ones quickly.
    static let commonCCs: [(number: Int, name: String)] = [
        (1, "Modulation Wheel"),
        (2, "Breath Controller"),
        (4, "Foot Controller"),
        (5, "Portamento Time"),
        (7, "Volume"),
        (8, "Balance"),
        (10, "Pan"),
        (11, "Expression"),
        (64, "Sustain Pedal"),
        (65, "Portamento On/Off"),
        (66, "Sostenuto Pedal"),
        (67, "Soft Pedal"),
        (71, "Resonance"),
        (74, "Cutoff Frequency"),
        (91, "Reverb Depth"),
        (93, "Chorus Depth"),
        (120, "All Sound Off"),
        (123, "All Notes Off"),
    ]

    /// Pre-built lookup so picker rendering does not have to do a linear scan
    /// through `commonCCs` for every CC number on every render.
    static let ccNameByNumber: [Int: String] = {
        Dictionary(uniqueKeysWithValues: commonCCs.map { ($0.number, $0.name) })
    }()

    /// Pre-built labels for all 128 CC numbers, used directly by the picker.
    /// Computed once at startup; avoids per-render string concatenation.
    static let ccPickerLabels: [(number: Int, label: String)] = {
        (0...127).map { n in
            if let name = ccNameByNumber[n] {
                return (n, "\(n) - \(name)")
            } else {
                return (n, "\(n)")
            }
        }
    }()

    /// Pre-built labels for all 128 MIDI note numbers.
    /// Computed once at startup; avoids per-render note-name calculations.
    static let notePickerLabels: [(number: Int, label: String)] = {
        (0...127).map { n in (n, "\(noteName(n)) (\(n))") }
    }()
}

// MARK: - MIDI Input

/// Reads incoming MIDI from every connected device and publishes it as
/// bindable state, so a MIDI keyboard, pad controller, or knob box can
/// drive keyboard / mouse / macro outputs the same way a gamepad does.
/// This is the mirror image of `MIDIService`, which SENDS MIDI.
///
/// Design notes:
///   - One CoreMIDI client + one input port, connected to every source.
///     Sources that appear or disappear are picked up by a setup-changed
///     notification, so hot-plugging a keyboard just works.
///   - State is polled by MappingEngine, not pushed, matching how every
///     other input source in the app behaves. Notes are held until note
///     off; CC / bend / aftertouch keep their last value.
///   - `@unchecked Sendable` with a single NSLock, following the
///     established pattern for services whose C callbacks fire off the
///     main actor (see DualSenseSupplementService / SteamControllerService).
final class MIDIInputService: @unchecked Sendable {

    nonisolated(unsafe) static let shared = MIDIInputService()

    /// Identifies one connected MIDI source.
    struct Device: Identifiable, Hashable {
        /// CoreMIDI unique ID, stringified. Stable across replug for most
        /// hardware, which is what makes it usable as a binding filter.
        let id: String
        let name: String
    }

    // MARK: State (lock-guarded)

    private let lock = NSLock()
    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var isSetup = false

    /// deviceID -> channel(1-16) -> note numbers currently held down.
    private var notesDown: [String: [Int: Set<Int>]] = [:]
    /// deviceID -> channel -> cc number -> last value (0-127).
    private var ccValues: [String: [Int: [Int: Int]]] = [:]
    /// deviceID -> channel -> last pitch bend, normalized -1...1.
    private var pitchBend: [String: [Int: Float]] = [:]
    /// deviceID -> channel -> last channel aftertouch (0-127).
    private var aftertouch: [String: [Int: Int]] = [:]
    /// deviceID -> channel -> program numbers seen since the last poll.
    /// Program Change is momentary, so these are consumed by the engine.
    private var programHits: [String: [Int: Set<Int>]] = [:]
    /// Connected sources, for the UI's device picker.
    private var devices: [Device] = []

    /// Fired on the main actor for every recognised message while a scan
    /// is active, so the binding editor's Scan button can capture MIDI.
    private var scanHandler: ((InputEvent) -> Void)?

    private init() {}

    // MARK: Lifecycle

    /// Open the client and connect to every current source. Safe to call
    /// repeatedly; later calls just re-scan for new devices.
    func start() {
        lock.lock()
        let already = isSetup
        lock.unlock()
        if already { connectAllSources(); return }

        var newClient: MIDIClientRef = 0
        let status = MIDIClientCreateWithBlock("InputConfig Input" as CFString, &newClient) { [weak self] notification in
            // Devices came or went: re-scan. The notification pointer is
            // only valid inside this block, and we only care that
            // *something* changed, so no payload parsing is needed.
            if notification.pointee.messageID == .msgSetupChanged {
                self?.connectAllSources()
            }
        }
        guard status == noErr else {
            NSLog("[MIDIInput] MIDIClientCreate failed: %d", status)
            return
        }

        var port: MIDIPortRef = 0
        let portStatus = MIDIInputPortCreateWithProtocol(
            newClient, "InputConfig In" as CFString, ._1_0, &port
        ) { [weak self] eventList, srcConnRefCon in
            // srcConnRefCon is the source's CoreMIDI unique ID, packed at
            // connect time, so we know which keyboard sent this without a
            // property lookup per message.
            let deviceID: String
            if let refCon = srcConnRefCon {
                deviceID = String(Int32(truncatingIfNeeded: Int(bitPattern: refCon)))
            } else {
                deviceID = "any"
            }
            self?.handle(eventList, deviceID: deviceID)
        }
        guard portStatus == noErr else {
            NSLog("[MIDIInput] MIDIInputPortCreate failed: %d", portStatus)
            MIDIClientDispose(newClient)
            return
        }

        lock.lock()
        client = newClient
        inputPort = port
        isSetup = true
        lock.unlock()

        connectAllSources()
        NSLog("[MIDIInput] started")
    }

    func stop() {
        lock.lock()
        let c = client, p = inputPort
        client = 0; inputPort = 0; isSetup = false
        notesDown.removeAll(); ccValues.removeAll(); pitchBend.removeAll()
        aftertouch.removeAll(); programHits.removeAll(); devices.removeAll()
        lock.unlock()
        if p != 0 { MIDIPortDispose(p) }
        if c != 0 { MIDIClientDispose(c) }
    }

    /// Connect the input port to every MIDI source currently present,
    /// skipping our own virtual output port so the app can't hear itself.
    private func connectAllSources() {
        lock.lock()
        let port = inputPort
        lock.unlock()
        guard port != 0 else { return }

        var found: [Device] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            let name = Self.endpointName(src)
            // Never connect to our own virtual source, or MIDI we send
            // would loop straight back in as input.
            if name == MIDIService.portName { continue }

            var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid)
            let deviceID = String(uid)
            found.append(Device(id: deviceID, name: name))

            // Pass the endpoint's unique ID as the connection refCon so
            // the read block knows which device a packet came from
            // without another property lookup per message.
            let refCon = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(uid)))
            MIDIPortConnectSource(port, src, refCon)
        }

        lock.lock()
        devices = found
        lock.unlock()
    }

    private static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr,
           let name = cf?.takeRetainedValue() as String? {
            return name
        }
        return "MIDI Device"
    }

    // MARK: Message handling

    private func handle(_ eventList: UnsafePointer<MIDIEventList>, deviceID: String) {
        // Attribute every word in this callback to its source. The port
        // callback is serial per connection, so a stored property is safe
        // and avoids threading the ID through the UMP decode.
        currentPacketDevice = deviceID
        // Universal MIDI Packet words. We only decode MIDI 1.0 channel
        // voice messages (message type 0x2), which is what every class
        // compliant controller sends over a 1.0 protocol port.
        let list = eventList.pointee
        var packet = list.packet
        for _ in 0..<list.numPackets {
            withUnsafePointer(to: packet.words) { tuplePtr in
                tuplePtr.withMemoryRebound(to: UInt32.self, capacity: Int(packet.wordCount)) { words in
                    for w in 0..<Int(packet.wordCount) {
                        decodeUMP(words[w])
                    }
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    /// Decode one 32-bit Universal MIDI Packet word carrying a MIDI 1.0
    /// channel voice message.
    private func decodeUMP(_ word: UInt32) {
        let messageType = UInt8((word >> 28) & 0xF)
        guard messageType == 0x2 else { return }   // MIDI 1.0 channel voice
        let status = UInt8((word >> 20) & 0xF)     // high nibble of status
        let channel = Int((word >> 16) & 0xF) + 1  // 1-16 for humans
        let data1 = Int((word >> 8) & 0x7F)
        let data2 = Int(word & 0x7F)
        // Device attribution: the read block gives us the source refCon,
        // but UMP decoding happens per word, so we resolve the device at
        // ingest time in `handle`. Falling back to "any" keeps bindings
        // with no device filter working.
        applyMessage(status: status, channel: channel,
                     data1: data1, data2: data2, deviceID: currentPacketDevice)
    }

    /// Device the packet currently being decoded arrived from. Set by the
    /// read block before decoding; single-threaded per port callback.
    private var currentPacketDevice: String = "any"

    private func applyMessage(status: UInt8, channel: Int,
                              data1: Int, data2: Int, deviceID: String) {
        var scanEvent: InputEvent?

        lock.lock()
        switch status {
        case 0x9 where data2 > 0:   // note on with velocity
            notesDown[deviceID, default: [:]][channel, default: []].insert(data1)
            scanEvent = .midi(.note, number: data1, channel: channel, deviceID: deviceID)
        case 0x8, 0x9:              // note off (or note on, velocity 0)
            notesDown[deviceID, default: [:]][channel, default: []].remove(data1)
        case 0xB:                   // control change
            ccValues[deviceID, default: [:]][channel, default: [:]][data1] = data2
            // Only offer a knob to Scan once it's moved meaningfully, so
            // idle controllers streaming zeros don't hijack the capture.
            if data2 > 0 {
                scanEvent = .midi(.cc, number: data1, channel: channel, deviceID: deviceID)
            }
        case 0xE:                   // pitch bend: 14-bit, centre 8192
            let raw = (data2 << 7) | data1
            pitchBend[deviceID, default: [:]][channel] = Float(raw - 8192) / 8192.0
            if abs(raw - 8192) > 2048 {
                scanEvent = .midi(.pitchBend, number: 0, channel: channel, deviceID: deviceID)
            }
        case 0xD:                   // channel aftertouch
            aftertouch[deviceID, default: [:]][channel] = data1
        case 0xC:                   // program change
            programHits[deviceID, default: [:]][channel, default: []].insert(data1)
            scanEvent = .midi(.programChange, number: data1, channel: channel, deviceID: deviceID)
        default:
            break
        }
        let handler = scanHandler
        lock.unlock()


        if let handler, let scanEvent {
            DispatchQueue.main.async { handler(scanEvent) }
        }
    }

    // MARK: Queries used by MappingEngine

    /// True while the given note is held. `channel`/`device` nil = any.
    func isNoteDown(_ note: Int, channel: Int?, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for (dev, byChannel) in notesDown where deviceID == nil || dev == deviceID {
            for (ch, notes) in byChannel where channel == nil || ch == channel {
                if notes.contains(note) { return true }
            }
        }
        return false
    }

    /// Last CC value 0-127, or nil if that CC has not been seen.
    func ccValue(_ cc: Int, channel: Int?, deviceID: String?) -> Int? {
        lock.lock(); defer { lock.unlock() }
        var best: Int?
        for (dev, byChannel) in ccValues where deviceID == nil || dev == deviceID {
            for (ch, ccs) in byChannel where channel == nil || ch == channel {
                if let v = ccs[cc] { best = max(best ?? 0, v) }
            }
        }
        return best
    }

    /// Last pitch bend, normalized -1...1 (0 = centre).
    func pitchBendValue(channel: Int?, deviceID: String?) -> Float {
        lock.lock(); defer { lock.unlock() }
        var out: Float = 0
        for (dev, byChannel) in pitchBend where deviceID == nil || dev == deviceID {
            for (ch, v) in byChannel where channel == nil || ch == channel {
                if abs(v) > abs(out) { out = v }
            }
        }
        return out
    }

    /// Last channel aftertouch 0-127.
    func aftertouchValue(channel: Int?, deviceID: String?) -> Int {
        lock.lock(); defer { lock.unlock() }
        var out = 0
        for (dev, byChannel) in aftertouch where deviceID == nil || dev == deviceID {
            for (ch, v) in byChannel where channel == nil || ch == channel {
                out = max(out, v)
            }
        }
        return out
    }

    /// Whether the given program change arrived since the last call, and
    /// clears it. Program Change is momentary, so it is consumed: the
    /// binding fires for exactly one poll frame.
    func consumeProgramChange(_ program: Int, channel: Int?, deviceID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var hit = false
        for (dev, byChannel) in programHits where deviceID == nil || dev == deviceID {
            for (ch, programs) in byChannel where channel == nil || ch == channel {
                if programs.contains(program) {
                    hit = true
                    programHits[dev]?[ch]?.remove(program)
                }
            }
        }
        return hit
    }

    /// Every MIDI source currently connected, for the editor's picker.
    func connectedDevices() -> [Device] {
        lock.lock(); defer { lock.unlock() }
        return devices
    }

    /// True when at least one MIDI source (other than our own output
    /// port) is connected. Drives the editor's "no MIDI device" hint.
    var hasDevices: Bool {
        lock.lock(); defer { lock.unlock() }
        return !devices.isEmpty
    }

    // MARK: Scanning

    func startScanning(_ handler: @escaping (InputEvent) -> Void) {
        start()
        lock.lock(); scanHandler = handler; lock.unlock()
    }

    func stopScanning() {
        lock.lock(); scanHandler = nil; lock.unlock()
    }

    /// Release all held state. Called when the engine stops so a note
    /// held at that moment can't leave a binding stuck on.
    func releaseAll() {
        lock.lock()
        notesDown.removeAll()
        programHits.removeAll()
        lock.unlock()
    }
}
