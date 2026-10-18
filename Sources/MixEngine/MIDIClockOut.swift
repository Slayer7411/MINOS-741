import Foundation
import CoreMIDI
import MixCore

/// MIDI-Clock (24 Takte je Viertel, Start/Continue/Stop, optional Song Position) an ein MIDI-Ziel, z. B. den USB-MIDI-Port
/// eines Pults. Wie Groove → MIDI: eigene Queue mit 10-ms-Takt, jedes Ereignis mit Host-Zeit, höchstens `lookahead`
/// voraus geplant. Nichts davon im Audio-Thread und nichts auf dem Hauptthread.
/// Messung: MixEngineTests/MIDIClockOutTests (virtuelles Ziel, Abstand der Takte beim Empfang).
public final class MIDIClockOut: @unchecked Sendable {
    /// Clock: Beat zu einer Host-Zeit (wann hörbar) und Tempo
    public struct Clock: Sendable {
        public var beat: Double
        public var hostTime: UInt64
        public var bpm: Double
        public init(beat: Double, hostTime: UInt64, bpm: Double) { self.beat = beat; self.hostTime = hostTime; self.bpm = bpm }
    }

    /// MIDI-Ziel (Eingang eines Geräts oder virtuelles Ziel)
    public struct Destination: Hashable, Sendable {
        public let endpoint: MIDIEndpointRef
        public let name: String
    }

    /// Takt der Queue und Vorlauf (wie Groove)
    public static let tick = 0.010
    public static let lookahead = 0.025

    /// Ziele, die ein Programm ansprechen kann (ohne private Ports)
    public static func destinations() -> [Destination] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i -> Destination? in
            let ep = MIDIGetDestination(i)
            guard ep != 0 else { return nil }
            var priv: Int32 = 0
            if MIDIObjectGetIntegerProperty(ep, kMIDIPropertyPrivate, &priv) == noErr, priv != 0 { return nil }
            return Destination(endpoint: ep, name: stringProperty(ep, kMIDIPropertyDisplayName) ?? stringProperty(ep, kMIDIPropertyName) ?? "?")
        }
    }

    private static func stringProperty(_ obj: MIDIObjectRef, _ key: CFString) -> String? {
        var s: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, key, &s) == noErr, let s else { return nil }
        return s.takeRetainedValue() as String
    }

    private let queue = DispatchQueue(label: "minos741.midiclock", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var target: MIDIEndpointRef = 0
    private var planner = MIDIClockPlanner()
    private var playing = false
    private var clock: (@Sendable () -> Clock?)?
    /// Versatz der Zeitstempel (positiv = später)
    private var offsetSeconds = 0.0
    private var buffer = [UInt8](repeating: 0, count: 8192)

    /// je gesendetem Ereignis (auf der Clock-Queue): Host-Zeit, Beat, Bytes – Test und Messung
    public var onSend: (@Sendable (_ hostTime: UInt64, _ beat: Double, _ bytes: [UInt8]) -> Void)?
    /// Fehler beim Anlegen des Ports
    public private(set) var lastError: String?

    public init() {}

    deinit {
        timer?.cancel()
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// läuft der Takt (Timer aktiv)
    public var running: Bool { queue.sync { timer != nil } }

    /// Ziel setzen (nil = keins). Läuft der Transport, startet er am neuen Ziel neu (Start/Position).
    public func setTarget(_ endpoint: MIDIEndpointRef?) {
        queue.async { [self] in
            guard endpoint != target else { return }
            target = endpoint ?? 0
            planner = MIDIClockPlanner(songPosition: planner.songPosition)
        }
    }

    /// Song Position senden: ändert die Art des nächsten Starts (läuft der Transport, startet er neu)
    public func setSongPosition(_ on: Bool) {
        queue.async { [self] in
            guard on != planner.songPosition else { return }
            planner = MIDIClockPlanner(songPosition: on)
        }
    }

    /// Versatz der Zeitstempel in ms (positiv = später)
    public func setOffset(ms: Double) {
        queue.async { [self] in offsetSeconds = ms / 1000 }
    }

    /// Transport: „läuft“ (Start/Continue beim Übergang, Stop beim Ende)
    public func setPlaying(_ on: Bool) {
        queue.async { [self] in playing = on }
    }

    /// Port anlegen (sonst beim ersten Start). Bleibt bis zum Ende des Programms.
    @discardableResult
    public func open() -> Bool { queue.sync { openLocked() } }

    /// Takt einschalten: `clock` liefert Beat, Host-Zeit und Tempo der Master-Clock (nil = noch nichts zu senden)
    public func start(clock: @escaping @Sendable () -> Clock?) {
        queue.async { [self] in
            self.clock = clock
            guard timer == nil else { return }
            guard openLocked() else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.tick, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.step() }
            timer = t
            t.resume()
        }
    }

    /// Takt aus: läuft der Transport, Stop senden; danach nichts mehr bis `start`
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            playing = false
            guard planner.running else { return }
            planner = MIDIClockPlanner(songPosition: planner.songPosition)
            send([(mach_absolute_time(), 0, [MIDIClock.stopByte])])
        }
    }

    private func openLocked() -> Bool {
        if port != 0 { return true }
        var st = MIDIClientCreateWithBlock("MINOS-741 Clock" as CFString, &client) { _ in }
        guard st == noErr else { lastError = "MIDIClientCreate \(st)"; return false }
        st = MIDIOutputPortCreate(client, "clock" as CFString, &port)
        guard st == noErr else { lastError = "MIDIOutputPortCreate \(st)"; return false }
        lastError = nil
        return true
    }

    /// ein Takt der Queue: Clock lesen, Fenster planen, senden
    private func step() {
        guard target != 0, let c = clock?(), c.bpm > 0 else { return }
        let now = mach_absolute_time()
        let spb = 60 / c.bpm
        // Beat jetzt (Zeitstempel = wann hörbar; liegt meist etwas in der Zukunft)
        let beatNow = c.beat + Self.seconds(from: c.hostTime, to: now) / spb
        let events = planner.plan(beatNow: beatNow, playing: playing, ahead: Self.lookahead / spb)
        guard !events.isEmpty else { return }
        var out = [(UInt64, Double, [UInt8])]()
        for e in events {
            let secs = (e.beat - c.beat) * spb + offsetSeconds
            let host = secs >= 0 ? c.hostTime &+ LinkSession.hostTicks(seconds: secs) : c.hostTime &- LinkSession.hostTicks(seconds: -secs)
            // Zeitstempel bleiben auf dem Raster, auch wenn die Queue spät dran ist: Vergangenes sendet CoreMIDI sofort,
            // ein auf „jetzt“ gesetzter Stempel würde den Takt dagegen aus dem Raster ziehen
            out.append((host, e.beat, e.message.bytes))
        }
        send(out)
    }

    private func send(_ ev: [(UInt64, Double, [UInt8])]) {
        guard port != 0, target != 0, !ev.isEmpty else { return }
        // höchstens 150 Ereignisse je Liste (wie Groove; eine Systemechtzeit ist ein Wort)
        for chunk in stride(from: 0, to: ev.count, by: 150).map({ Array(ev[$0..<min(ev.count, $0 + 150)]) }) {
            buffer.withUnsafeMutableBytes { raw in
                let list = raw.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
                var pkt: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
                for (host, _, bytes) in chunk where pkt != nil {
                    // UMP Systemnachrichten (Typ 1): Echtzeit 0xF8–0xFF, Song Position 0xF2 (drei Bytes)
                    var word = UInt32(0x1) << 28 | UInt32(bytes[0]) << 16
                    if bytes.count > 1 { word |= UInt32(bytes[1] & 0x7F) << 8 }
                    if bytes.count > 2 { word |= UInt32(bytes[2] & 0x7F) }
                    pkt = MIDIEventListAdd(list, raw.count, pkt!, host, 1, &word)
                }
                MIDISendEventList(port, target, list)
            }
        }
        if let cb = onSend { for (h, beat, b) in ev { cb(h, beat, b) } }
    }

    static func seconds(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? Double(LinkSession.micros(hostTicks: b - a)) / 1e6 : -Double(LinkSession.micros(hostTicks: a - b)) / 1e6
    }
}
