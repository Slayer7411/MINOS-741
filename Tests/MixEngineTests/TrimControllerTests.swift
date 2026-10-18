import Foundation
import Testing
import MixCore
import MixEngine

/// Schnitt und Grid-Änderungen im Steuerkern, ohne Audiogerät (Positionen über ausstehende Sprünge ablesbar).
/// 120 BPM, Grid ab 0 -> Beat = 0,5 s; Datei 24 s, Schnitt 2–20 s.
private func controller(trim: TrackTrim = TrackTrim(start: 2, end: 20), gridEdited: Bool = false) async throws -> (MixController, URL) {
    let url = try writeWAV(rate: 44100, channels: 2, seconds: 24)
    var t = Track(key: url.path, path: url.path)
    t.bpm = 120
    t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
    let c = testController()
    c.load(t, deck: 0, trim: trim, gridEdited: gridEdited)
    for _ in 0..<100 where c.trackAudio(0) == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(c.trackAudio(0) != nil)
    return (c, url)
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

@Test func loadWithTrimPutsCueAtTrimStart() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    let s = c.snapshot().decks[0]
    #expect(s.trim == TrackTrim(start: 2, end: 20) && s.playRange == 2...20)
    #expect(near(s.cuePoint, 2))          // Load-Cue (Grid bei 0) liegt davor
    #expect(!s.gridEdited)
}

@Test func seekAndBeatjumpStayInTrim() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.seek(0, seconds: 0.5)
    #expect(near(c.position(0), 2))
    c.seek(0, seconds: 23)
    #expect(near(c.position(0), 20))
    c.seek(0, seconds: 19)
    c.beatjump(0, beats: 4)               // 21 s -> ganze Beats zurück vor das Ende
    #expect(near(c.position(0), 19.5))
    c.seek(0, seconds: 3)
    c.beatjump(0, beats: -4)              // 1 s -> ganze Beats vor in den Schnitt
    #expect(near(c.position(0), 2))
}

@Test func autoLoopIsShortenedAtTrimEnd() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.seek(0, seconds: 19)
    c.autoLoop(0, size: 4)                // 19–21 -> 19–20
    let l = c.engine.loop(0)
    #expect(l.active && near(l.start, 19) && near(l.end, 20))
    // Loop wandert per Beatjump nicht aus dem Schnitt
    c.beatjump(0, beats: 1)
    #expect(near(c.engine.loop(0).start, 19) && near(c.position(0), 19))
}

@Test func trimHereSnapsWithQuantize() async throws {
    let (c, url) = try await controller(trim: TrackTrim())
    defer { try? FileManager.default.removeItem(at: url) }
    c.seek(0, seconds: 5.2)
    #expect(c.trimHere(0, end: false))
    #expect(c.snapshot().decks[0].trim == TrackTrim(start: 5))
    c.seek(0, seconds: 5.2)
    #expect(c.trimHere(0, end: false, free: true))
    #expect(c.snapshot().decks[0].trim.start == 5.2)
    c.seek(0, seconds: 5.7)
    #expect(!c.trimHere(0, end: true))    // 6 – 5,2 < 1 s: bleibt
    c.seek(0, seconds: 18.1)
    #expect(c.trimHere(0, end: true))
    #expect(c.snapshot().decks[0].trim == TrackTrim(start: 5.2, end: 18))
    c.clearTrim(0)
    #expect(c.snapshot().decks[0].trim.isEmpty && c.snapshot().decks[0].playRange == 0...c.snapshot().decks[0].duration)
}

@Test func cueAndLoopMoveIntoANewTrim() async throws {
    let (c, url) = try await controller(trim: TrackTrim())
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(near(c.snapshot().decks[0].cuePoint, 0))
    c.seek(0, seconds: 10)
    c.autoLoop(0, size: 8)                // 10–14
    #expect(c.setTrim(0, TrackTrim(start: 3, end: 12)))
    let s = c.snapshot().decks[0]
    #expect(near(s.cuePoint, 3))
    let l = c.engine.loop(0)
    #expect(s.loopActive && l.active && near(l.start, 10) && near(l.end, 12))
    #expect(!c.setTrim(0, TrackTrim(start: 11, end: 11.5)))   // zu kurz: alter Schnitt bleibt
    #expect(c.snapshot().decks[0].trim == TrackTrim(start: 3, end: 12))
}

@Test func gridEditsAreMarkedManual() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    var t = Track(key: url.path, path: url.path)
    t.bpm = 120
    t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
    c.shiftGrid(0, ms: 10)
    #expect(c.snapshot().decks[0].gridEdited && near(c.snapshot().decks[0].grid!.anchor, 0.01))
    c.resetGrid(0, original: t)
    #expect(!c.snapshot().decks[0].gridEdited && near(c.snapshot().decks[0].grid!.anchor, 0))
    c.seek(0, seconds: 7.25)
    c.setGridAnchorHere(0)
    #expect(c.snapshot().decks[0].gridEdited && near(c.snapshot().decks[0].grid!.anchor, 7.25))
    let (c2, url2) = try await controller(gridEdited: true)
    defer { try? FileManager.default.removeItem(at: url2) }
    #expect(c2.snapshot().decks[0].gridEdited)
}

@Test func tapGridSetsBPM() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    for (i, t) in [100.0, 100.47, 100.94, 101.41].enumerated() {
        c.tapGrid(0, at: t)
        #expect(c.snapshot().decks[0].gridEdited == (i == 3))
    }
    #expect(abs(c.snapshot().decks[0].grid!.bpm - 127.66) < 0.01)
    c.tapGrid(0, at: 110)                 // Pause > 2 s: beginnt neu, ändert nichts
    #expect(abs(c.snapshot().decks[0].grid!.bpm - 127.66) < 0.01)
}

@Test func loopFromRangeJumpsInAndKeepsTrim() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.seek(0, seconds: 3)
    #expect(c.setLoop(0, start: 8, end: 12))   // 8 Beats, Position davor -> Sprung an den Anfang
    var l = c.engine.loop(0)
    #expect(l.active && near(l.start, 8) && near(l.end, 12) && near(c.position(0), 8))
    #expect(c.snapshot().decks[0].loopSize == 8)
    #expect(c.setLoop(0, start: 18, end: 22))  // über das Schnitt-Ende -> gekürzt
    l = c.engine.loop(0)
    #expect(near(l.start, 18) && near(l.end, 20))
    #expect(!c.setLoop(0, start: 21, end: 23))  // ganz außerhalb des Schnitts
}

/// aktiver Loop: Beatjump springt um die Loop-Länge (nicht die Jump-Größe) und nimmt den Loop mit
@Test func beatjumpInsideLoopMovesByLoopLength() async throws {
    let (c, url) = try await controller(trim: TrackTrim())
    defer { try? FileManager.default.removeItem(at: url) }
    c.seek(0, seconds: 4)
    c.setJumpSize(0, 16)
    c.autoLoop(0, size: 4)                // 4 Beats = 2 s ab 4 s
    let before = c.engine.loop(0)
    #expect(before.active && c.snapshot().decks[0].loopActive)
    c.beatjump(0, beats: 16)
    #expect(near(c.position(0), 6))       // + 4 Beats, nicht + 16
    let l = c.engine.loop(0)
    #expect(near(l.start, before.start + 2) && near(l.end, before.end + 2))
    c.beatjump(0, beats: -16)
    #expect(near(c.position(0), 4))
}
