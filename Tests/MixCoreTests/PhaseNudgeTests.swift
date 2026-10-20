import Testing
@testable import MixCore

/// 5 ms Takt (wie der Steuer-Tick)
private let nudgeDt = 0.005

@Test func phaseNudgeConstantErrorKeepsOneSign() {
    var n = PhaseNudge()
    var rates: [Double] = []
    for _ in 0..<400 { rates.append(n.update(error: 0.02, dt: nudgeDt)) }
    #expect(rates.last! < 0)
    #expect(rates.dropFirst(100).allSatisfy { $0 < 0 })
}

/// Fehler wechselt von Block zu Block das Vorzeichen (Blockstufen um Null): die Rate bleibt ruhig
@Test func phaseNudgeAlternatingErrorDoesNotFlipNudge() {
    var n = PhaseNudge()
    var flips = 0, last = 0.0
    for k in 0..<800 {
        let r = n.update(error: k % 2 == 0 ? 0.006 : -0.006, dt: nudgeDt)
        if r != 0, last != 0, (r > 0) != (last > 0) { flips += 1 }
        if r != 0 { last = r }
    }
    #expect(flips == 0)
    #expect(n.active == false)
}

/// Einmal eingerastet, bleibt die Korrektur bei Fehlern unter dem Eintrittswert erhalten
@Test func phaseNudgeHysteresisHoldsBetweenThresholds() {
    var n = PhaseNudge()
    for _ in 0..<200 { _ = n.update(error: 0.02, dt: nudgeDt) }
    #expect(n.active)
    for _ in 0..<400 { _ = n.update(error: 0.003, dt: nudgeDt) }
    #expect(n.active)
    for _ in 0..<400 { _ = n.update(error: 0.0, dt: nudgeDt) }
    #expect(!n.active)
}

/// Ein Fehler, der klein bleibt, schaltet nie ein
@Test func phaseNudgeSmallErrorStaysOff() {
    var n = PhaseNudge()
    for _ in 0..<400 { #expect(n.update(error: 0.003, dt: nudgeDt) == 0) }
}
