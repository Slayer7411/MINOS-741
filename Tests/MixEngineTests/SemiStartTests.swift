import Foundation
import Testing
import MixCore
import MixEngine

/// Steuerkern ohne Audiogerät: Positionen bleiben stehen (kein Render), Sprünge sind direkt ablesbar.
/// Beide Decks: 120 BPM, Grid ab 0 -> Beat = 0,5 s.
private func controller() async throws -> (MixController, URL) {
    let url = try writeWAV(rate: 44100, channels: 2, seconds: 8)
    var t = Track(key: url.path, path: url.path)
    t.bpm = 120
    t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
    let c = testController()
    c.load(t, deck: 0)
    c.load(t, deck: 1)
    for _ in 0..<100 where c.trackAudio(0) == nil || c.trackAudio(1) == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(c.trackAudio(0) != nil && c.trackAudio(1) != nil)
    c.seek(0, seconds: 1.1)   // A: Beat 2,2
    c.togglePlay(0)           // A läuft und ist Master
    c.seek(1, seconds: 2.0)   // B: Beat 4,0 -> Phase −0,2
    c.setTempo(1, 2)
    return (c, url)
}

@Test func semiStartJumpsIntoPhase() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.setSemiSync(true)
    c.togglePlay(1)
    #expect(abs(c.phaseError(1) ?? 1) < 1e-6)
    #expect(abs(c.position(1) - 2.1) < 1e-6)   // nächster Beat: +0,1 s, kein ganzer Beat
    let s = c.snapshot().decks[1]
    #expect(s.tempoPct == 2 && !s.sync && s.playing)
}

@Test func semiStartViaCupAndCue() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.setSemiSync(true)
    c.cueDown(1)   // steht neben dem Cue: setzt den Cue auf 2,0
    c.cueDown(1)   // am Cue: Vorhören startet in Phase
    #expect(abs(c.phaseError(1) ?? 1) < 1e-6)
    c.cueUp(1)
    #expect(abs(c.position(1) - 2.0) < 1e-6)
    c.cup(1)
    #expect(abs(c.phaseError(1) ?? 1) < 1e-6)
    #expect(c.snapshot().decks[1].tempoPct == 2)
}

@Test func noSemiStartWithoutSemiOrMaster() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.togglePlay(1)   // SEMI aus: kein Sprung
    #expect(abs(c.position(1) - 2.0) < 1e-6)
    c.togglePlay(1)
    c.togglePlay(0)   // A steht -> kein Master
    c.setSemiSync(true)
    c.togglePlay(1)
    #expect(abs(c.position(1) - 2.0) < 1e-6)
}
