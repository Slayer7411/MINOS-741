import Foundation
import Testing
import MixCore
import MixEngine

/// Auto-Loop beim Laden. 128 BPM -> Beat 0,46875 s, 8-Takt-Phrase 15 s.
private let beat = 60.0 / 128
private let rate = 44100.0

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

@Test(arguments: [4, 8, 16, 32])
func autoLoopLengthIsSampleExact(bars: Int) {
    let g = BeatGrid(anchor: 0.3, bpm: 128)
    let r = MixController.autoLoopRange(grid: g, bars: bars, range: 0...600)
    #expect(r.map { near($0.start, 0.3) } == true)
    let frames = r.map { ($0.end - $0.start) * rate } ?? 0
    #expect(abs(frames - Double(bars * 4) * beat * rate) < 0.5)
    #expect(abs(frames - frames.rounded()) < 1e-3)   // 4/4 bei 128 BPM: ganze Samples
}

@Test func autoLoopStartsOnPhraseAnchor() {
    let g = BeatGrid(anchor: 0.3, bpm: 128)
    let r = MixController.autoLoopRange(grid: g, phraseAnchor: 0.3 + 2 * beat, bars: 16, range: 0...600)
    #expect(r.map { near($0.start, 0.3 + 2 * beat) && near($0.end, 0.3 + 66 * beat) } == true)
}

@Test func autoLoopStartsOnFirstFullPhraseOfTrack() {
    // Anker mitten im Track: erster Phrasenbeginn ab 0 liegt 1 Phrase davor
    let g = BeatGrid(anchor: 16.0, bpm: 128)
    let r = MixController.autoLoopRange(grid: g, bars: 4, range: 0...600)
    #expect(r.map { near($0.start, 1.0) && near($0.end, 8.5) } == true)
}

@Test func autoLoopStaysInsideCut() {
    let g = BeatGrid(anchor: 0.3, bpm: 128)
    let r = MixController.autoLoopRange(grid: g, bars: 16, range: 10...120)   // Schnitt IN 10 s -> Phrase bei 15,3 s
    #expect(r.map { near($0.start, 15.3) && near($0.end, 45.3) } == true)
    #expect(MixController.autoLoopRange(grid: g, bars: 16, range: 10...40) == nil)   // passt nicht vor Schnitt OUT
}

@Test func autoLoopNeedsGridAndLength() {
    #expect(MixController.autoLoopRange(grid: nil, bars: 16, range: 0...600) == nil)
    #expect(MixController.autoLoopRange(grid: BeatGrid(anchor: 0, bpm: 128), bars: 0, range: 0...600) == nil)
}

// MARK: Laden

private func load(_ cues: [Cue] = [], bpm: Double = 128, trim: TrackTrim = TrackTrim(),
                  _ edit: (inout EnginePrefs) -> Void = { _ in }) async throws -> (MixController, URL) {
    let url = try writeWAV(rate: rate, channels: 2, seconds: 60)
    var t = Track(key: url.path, path: url.path)
    t.bpm = bpm
    t.cues = [Cue(name: "Grid", kind: .grid, startMs: 300, lengthMs: 0, hotcue: -1)] + cues
    let c = MixController()
    var p = EnginePrefs()
    p.phraseAnchor = .off
    // der Wächter (4 s ohne Daten) gilt nur hängenden Dekodern; unter Last der ganzen Suite darf er das Laden nicht abbrechen
    p.loadTimeout = 60
    edit(&p)
    c.setPrefs(p)
    c.load(t, deck: 0, trim: trim)
    let deadline = Date().addingTimeInterval(60)
    while c.trackAudio(0) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(c.trackAudio(0) != nil, "\(c.snapshot().decks[0].error ?? "-")")
    return (c, url)
}

@Test func autoLoopSetOnLoadInactive() async throws {
    let (c, url) = try await load()
    defer { try? FileManager.default.removeItem(at: url) }
    let l = c.engine.loop(0), s = c.snapshot().decks[0]
    #expect(!l.active && !s.loopActive && s.autoLoop)
    #expect(near(l.start, 0.3) && near(l.end, 0.3 + 64 * beat))   // Standard 16 Takte
    #expect(c.deckEdit(0).autoLoop)
}

@Test func reloopJumpsIntoAutoLoop() async throws {
    let (c, url) = try await load { $0.autoLoopBars = 8 }
    defer { try? FileManager.default.removeItem(at: url) }
    c.seek(0, seconds: 40)
    c.reloop(0)
    let l = c.engine.loop(0), s = c.snapshot().decks[0]
    #expect(l.active && s.loopActive && !s.autoLoop)
    #expect(near(l.start, 0.3) && near(l.end, 0.3 + 32 * beat))
    #expect(near(c.position(0), 0.3))
}

@Test func loopKeyTakesAutoLoopInsideWithoutJump() async throws {
    let (c, url) = try await load { $0.autoLoopBars = 4 }
    defer { try? FileManager.default.removeItem(at: url) }
    c.seek(0, seconds: 2)
    c.autoLoop(0)
    let l = c.engine.loop(0)
    #expect(l.active && near(l.start, 0.3) && near(l.end, 0.3 + 16 * beat) && near(c.position(0), 2))
    #expect(c.snapshot().decks[0].loopSize == 16 && !c.snapshot().decks[0].autoLoop)
    c.exitLoop(0)
    c.seek(0, seconds: 30)   // weit hinter dem Auto-Loop: normaler Loop an der Position
    c.autoLoop(0, size: 4)
    #expect(c.engine.loop(0).start > 29)
}

@Test func autoLoopWithinCut() async throws {
    let (c, url) = try await load(trim: TrackTrim(start: 10, end: 59))
    defer { try? FileManager.default.removeItem(at: url) }
    let l = c.engine.loop(0)
    #expect(c.snapshot().decks[0].autoLoop && near(l.start, 15.3) && near(l.end, 45.3))
}

@Test func noAutoLoopWithStoredLoop() async throws {
    let memory = Cue(name: "Loop", kind: .loop, startMs: 20000, lengthMs: 2000, hotcue: -1)
    let hot = Cue(name: "Loop", kind: .loop, startMs: 20000, lengthMs: 2000, hotcue: 2)
    for cue in [memory, hot] {
        let (c, url) = try await load([cue])
        defer { try? FileManager.default.removeItem(at: url) }
        let l = c.engine.loop(0)
        #expect(!c.snapshot().decks[0].autoLoop && !l.active && l.end == 0)
    }
}

@Test func noAutoLoopWhenOffOrWithoutGrid() async throws {
    let (off, u1) = try await load { $0.autoLoopBars = 0 }
    defer { try? FileManager.default.removeItem(at: u1) }
    #expect(!off.snapshot().decks[0].autoLoop && off.engine.loop(0).end == 0)
    let (none, u2) = try await load(bpm: 0)
    defer { try? FileManager.default.removeItem(at: u2) }
    #expect(!none.snapshot().decks[0].autoLoop && none.engine.loop(0).end == 0)
    none.reloop(0)
    #expect(!none.engine.loop(0).active)
}

@Test func undoOfReloopRestoresAutoLoop() async throws {
    let (c, url) = try await load()
    defer { try? FileManager.default.removeItem(at: url) }
    let before = c.deckEdit(0)
    c.reloop(0)
    #expect(!c.snapshot().decks[0].autoLoop)
    c.restoreDeckEdit(0, before, [.loop, .position], position: before.position)
    let l = c.engine.loop(0)
    #expect(c.snapshot().decks[0].autoLoop && !l.active && near(l.start, 0.3))
}
