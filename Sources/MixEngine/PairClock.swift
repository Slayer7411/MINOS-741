import Foundation

/// Folgen einer Clock: Tempo und Phase kommen von außen (Link-Sitzung oder Takt über den Zwei-Mac-Kanal).
/// `follow` gibt Tempo und Korrektur für die eigene Clock zurück, nil = keine Quelle (Clock läuft frei).
public protocol TempoFollowSource: AnyObject {
    func follow(beat: Double, hostTime: UInt64) -> (bpm: Double, action: LinkFollowPolicy.Action)?
    func resetPolicies()
}

extension LinkSession: TempoFollowSource {}

public enum PairClock {
    /// Host-Zeit in Mikrosekunden (dieselbe Uhr wie Link und die Clock-Stempel)
    public static func nowMicros() -> Int64 { LinkSession.micros(hostTicks: mach_absolute_time()) }

    /// Phasenabstand in Beats (−quantum/2 … quantum/2): eigener Beat minus Bezugs-Beat, gleiche Mathematik wie Link
    public static func phaseDiff(beat: Double, reference: Double, quantum: Double = 4) -> Double {
        var d = (beat - reference).truncatingRemainder(dividingBy: quantum)
        if d > quantum / 2 { d -= quantum } else if d < -quantum / 2 { d += quantum }
        return d
    }

    /// Ausbleiben der Takt-Nachrichten, ab dem der Folger keinen Takt mehr hat (Clock läuft frei, Tempo bleibt)
    public static let staleMicros: Int64 = 2_000_000
}

/// Uhrenabgleich über die Verbindung (NTP-artig): Ping (t0) und Pong (t1 Empfang, t2 Antwort) liefern den Versatz
/// `remote − local` und die Laufzeit. Gemittelt werden die `best` Samples mit der kleinsten Laufzeit im Fenster: dort
/// wartet das Paket am wenigsten, und die unterschiedliche Wartezeit beider Richtungen mittelt sich heraus.
public struct PairClockSync: Sendable {
    public static let window = 64
    public static let best = 16
    private var samples: [(delay: Int64, offset: Int64)] = []

    public init() {}

    /// t0 = eigener Sendezeitpunkt, t1/t2 = Empfang/Antwort des anderen, t3 = eigener Empfang (Mikrosekunden)
    public mutating func add(t0: Int64, t1: Int64, t2: Int64, t3: Int64) {
        let offset = ((t1 - t0) + (t2 - t3)) / 2
        let delay = max(0, (t3 - t0) - (t2 - t1))
        samples.append((delay, offset))
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    /// Versatz `remote − local` in Mikrosekunden; nil ohne Sample
    public var offset: Int64? {
        let low = samples.sorted { $0.delay < $1.delay }.prefix(Self.best)
        guard !low.isEmpty else { return nil }
        return low.reduce(Int64(0)) { $0 + $1.offset } / Int64(low.count)
    }
    public var count: Int { samples.count }
}

/// Die Clock der Führung als Quelle für einen Folger: letzte Nachricht (Tempo, Beat zur Host-Zeit) und Extrapolation.
/// Ohne Nachricht seit `PairClock.staleMicros` liefert sie nichts: das Tempo bleibt, wie es war. Schreiber (Hauptthread)
/// und Leser (Steuer-Queue) teilen sich das Schloss.
public final class PairClockFollower: TempoFollowSource, @unchecked Sendable {
    private let lock = NSLock()
    private var bpm = 0.0
    private var anchorBeat = 0.0
    private var anchorMicros: Int64?
    private var policy = LinkFollowPolicy()
    private let quantum: Double

    public init(quantum: Double = 4) { self.quantum = quantum }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    /// Nachricht der Führung: Tempo und Beat, der zur Host-Zeit `atMicros` (eigene Uhr) hörbar ist
    public func accept(bpm: Double, beat: Double, atMicros: Int64) {
        guard bpm > 0, beat.isFinite else { return }
        locked { self.bpm = bpm; anchorBeat = beat; anchorMicros = atMicros }
    }

    /// Tempo und Beat der Führung zur Host-Zeit `micros`; nil ohne Nachricht, die jünger als `staleMicros` ist
    public func sample(atMicros micros: Int64) -> (bpm: Double, beat: Double)? {
        locked {
            guard let a = anchorMicros, micros - a <= PairClock.staleMicros else { return nil }
            return (bpm, anchorBeat + Double(micros - a) / 60_000_000 * bpm)
        }
    }

    /// letzte Nachricht ist älter als `PairClock.staleMicros` (oder keine da)
    public func isStale(now: Int64) -> Bool { sample(atMicros: now) == nil }

    public func resetPolicies() { locked { policy.reset() } }

    public func follow(beat: Double, hostTime: UInt64) -> (bpm: Double, action: LinkFollowPolicy.Action)? {
        let t = LinkSession.micros(hostTicks: hostTime)
        return locked {
            guard let a = anchorMicros, t - a <= PairClock.staleMicros else { return nil }
            let ref = anchorBeat + Double(t - a) / 60_000_000 * bpm
            let diff = PairClock.phaseDiff(beat: beat, reference: ref, quantum: quantum)
            return (bpm, policy.step(diff: diff))
        }
    }
}
