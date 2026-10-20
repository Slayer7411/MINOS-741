import Foundation
import Testing
import MixCore
import MixEngine

/// Neue Analyse auf einem geladenen Deck: Grid, BPM, Key, Lautheit sofort, ohne neu laden; eigenes Grid bleibt
@Test func analysisReachesTheLoadedDeck() async throws {
    let url = try writeWAV(rate: 44100, channels: 2, seconds: 12)
    var t = Track(key: url.path, path: url.path)
    t.bpm = 120
    t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
    let c = testController()
    c.load(t, deck: 0)
    try await awaitLoaded(c)
    #expect(c.trackAudio(0) != nil)
    var n = t
    n.bpm = 128; n.musicalKey = 3; n.keyText = Track.openKey(code: 3); n.perceivedDb = -2
    n.cues = [Cue(name: "AutoGrid", kind: .grid, startMs: 250, lengthMs: 0, hotcue: -1)]
    c.applyAnalysis(0, track: n)
    let s = c.snapshot().decks[0]
    #expect(abs((s.grid?.bpm ?? 0) - 128) < 1e-9 && abs((s.grid?.anchor ?? 0) - 0.25) < 1e-9)
    #expect(s.track?.musicalKey == 3 && s.track?.perceivedDb == -2)
    // von Hand geändertes Grid bleibt bei der nächsten Analyse
    c.setGridBPM(0, 125)
    n.bpm = 130
    c.applyAnalysis(0, track: n)
    #expect(abs((c.snapshot().decks[0].grid?.bpm ?? 0) - 125) < 1e-9)
    #expect(c.snapshot().decks[0].track?.bpm == 130)
}
