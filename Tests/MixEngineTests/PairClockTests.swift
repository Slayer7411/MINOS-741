import Foundation
import Testing
@testable import MixCore
@testable import MixEngine

/// Gleichförmige Zufallszahl 0…1 (fest gesät, reproduzierbar)
private struct Jitter {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

@Test func pairClockOffsetEstimateWithinOneMillisecond() {
    // Gegenseite 37 ms voraus; Hinweg 2 ms + Jitter bis 8 ms, Rückweg 1,5 ms + Jitter bis 8 ms (asymmetrisch)
    let trueOffset: Int64 = 37_000
    var rng = Jitter(state: 42)
    var sync = PairClockSync()
    var localNow: Int64 = 1_000_000
    for _ in 0..<200 {
        let t0 = localNow
        let d1 = 2_000 + Int64(rng.next() * 8_000)
        let d2 = 1_500 + Int64(rng.next() * 8_000)
        let t1 = t0 + d1 + trueOffset          // Gegenseite empfängt (ihre Uhr)
        let t2 = t1 + 50                        // antwortet nach 50 µs
        let t3 = t0 + d1 + 50 + d2              // eigener Empfang (eigene Uhr)
        sync.add(t0: t0, t1: t1, t2: t2, t3: t3)
        localNow += 500_000
    }
    let est = sync.offset ?? .min
    #expect(sync.count == PairClockSync.window)
    #expect(abs(est - trueOffset) < 1_000, "Versatz-Fehler \(est - trueOffset) µs")
}

@Test func pairClockFollowerLocksPhaseFromClockMessages() {
    // Führung 126 BPM, eigene Clock 120 BPM und 3,2 Beats daneben; Takt-Nachrichten alle 50 ms, 5 ms Laufzeit
    let leaderBPM = 126.0, dt = 0.005
    let follower = PairClockFollower()
    var ownBPM = 120.0, ownBeat = 3.2
    var leaderBeat: (Double) -> Double = { t in 2.0 + leaderBPM / 60 * t }
    var maxAbs = 0.0
    for k in 0..<6_000 {
        let t = Double(k) * dt
        if k % 10 == 0 {
            // Stempel der Führung (ihre Host-Zeit, µs) kommt 5 ms später an
            let sent = Int64((t - 0.005) * 1_000_000)
            follower.accept(bpm: leaderBPM, beat: leaderBeat(t - 0.005), atMicros: sent)
        }
        ownBeat += ownBPM / 60 * dt
        if let f = follower.follow(beat: ownBeat, hostTime: LinkSession.hostTicks(seconds: t)) {
            if abs(f.bpm - ownBPM) > 0.0005 { ownBPM = f.bpm }
            switch f.action {
            case .none: break
            case .trim(let d), .jump(let d): ownBeat -= d
            }
        }
        if t > 20 { maxAbs = max(maxAbs, abs(PairClock.phaseDiff(beat: ownBeat, reference: leaderBeat(t)))) }
    }
    #expect(abs(ownBPM - leaderBPM) < 0.001)
    #expect(maxAbs < 0.005, "Phasenfehler \(maxAbs) Beats")
}

@Test func pairClockLeaderLossFreezesTempo() {
    let follower = PairClockFollower()
    let leaderBPM = 126.0, dt = 0.005
    var ownBPM = 120.0, ownBeat = 0.0
    let lost = 5.0                                     // ab hier keine Nachrichten mehr
    var lastBPM = ownBPM
    for k in 0..<3_000 {                               // 15 s
        let t = Double(k) * dt
        if t < lost, k % 10 == 0 {
            follower.accept(bpm: leaderBPM, beat: 2.0 + leaderBPM / 60 * t, atMicros: Int64(t * 1_000_000))
        }
        ownBeat += ownBPM / 60 * dt
        if let f = follower.follow(beat: ownBeat, hostTime: LinkSession.hostTicks(seconds: t)) {
            if abs(f.bpm - ownBPM) > 0.0005 { ownBPM = f.bpm }
            switch f.action {
            case .none: break
            case .trim(let d), .jump(let d): ownBeat -= d
            }
        }
        if t > lost + 2.5 {
            // zwei Sekunden nach dem letzten Takt: keine Quelle mehr, Tempo und Lauf bleiben
            #expect(follower.follow(beat: ownBeat, hostTime: LinkSession.hostTicks(seconds: t)) == nil)
            #expect(follower.isStale(now: Int64(t * 1_000_000)))
        }
        lastBPM = ownBPM
    }
    #expect(abs(lastBPM - leaderBPM) < 0.001, "Tempo springt nicht: \(lastBPM)")
    #expect(ownBeat.isFinite)
}

@Test func pairClockTakeoverKeepsTempo() {
    // Führung 126 BPM, dann ausgeblieben. Nach der Übernahme-Frist (3 s) hat der Nachfolger noch dasselbe Tempo:
    // seine Clock läuft mit dem zuletzt gefolgten Tempo weiter, kein Sprung
    let follower = PairClockFollower()
    let leaderBPM = 126.0, dt = 0.005, lost = 5.0
    var ownBPM = 120.0, ownBeat = 0.0
    var bpmAtTakeover = 0.0
    for k in 0..<2_400 {                               // 12 s
        let t = Double(k) * dt
        if t < lost, k % 10 == 0 {
            follower.accept(bpm: leaderBPM, beat: 2.0 + leaderBPM / 60 * t, atMicros: Int64(t * 1_000_000))
        }
        ownBeat += ownBPM / 60 * dt
        if let f = follower.follow(beat: ownBeat, hostTime: LinkSession.hostTicks(seconds: t)) {
            if abs(f.bpm - ownBPM) > 0.0005 { ownBPM = f.bpm }
            switch f.action {
            case .none: break
            case .trim(let d), .jump(let d): ownBeat -= d
            }
        }
        if abs(t - (lost + 3.5)) < dt / 2 { bpmAtTakeover = ownBPM }
    }
    #expect(PairTakeover.due(silentMicros: 3_500_000))
    #expect(abs(bpmAtTakeover - leaderBPM) < 0.001, "Tempo beim Übernehmen: \(bpmAtTakeover)")
    #expect(abs(ownBPM - leaderBPM) < 0.001)
}
