import Foundation
import Testing
import MixCore
import MixEngine

/// Loop-Snap ohne Audiogerät: Position bleibt stehen, Loop direkt aus der Engine ablesbar.
/// 120 BPM, Grid ab 0 -> Beat = 0,5 s, 4-Takt-Grenzen bei 0, 8, 16 s.
/// Loop-Cue (Memory) 4,5–6,5 s, Hotcue 5 als Loop 20,25–21,25 s.
private func controller(snap: Bool = true, _ edit: (inout EnginePrefs) -> Void = { _ in }) async throws -> (MixController, URL) {
    let url = try writeWAV(rate: 44100, channels: 2, seconds: 24)
    var t = Track(key: url.path, path: url.path)
    t.bpm = 120
    t.cues = [
        Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1),
        Cue(name: "Loop", kind: .loop, startMs: 4500, lengthMs: 2000, hotcue: -1),
        Cue(name: "Loop", kind: .loop, startMs: 20250, lengthMs: 1000, hotcue: 4),
    ]
    let c = testController()
    var p = EnginePrefs()
    p.snap = snap
    edit(&p)
    c.setPrefs(p)
    c.load(t, deck: 0)
    for _ in 0..<100 where c.trackAudio(0) == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(c.trackAudio(0) != nil)
    #expect(c.snapshot().decks[0].loopSize == 4)
    return (c, url)
}

private func loopAt(_ c: MixController, _ pos: Double) -> (start: Double, end: Double, pos: Double) {
    c.seek(0, seconds: pos)
    c.autoLoop(0)
    let l = c.engine.loop(0)
    #expect(l.active && c.snapshot().decks[0].loopActive)
    return (l.start, l.end, c.position(0))
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

@Test func loopSnapTakesLoopCueAhead() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    let l = loopAt(c, 3.5)   // Loop-Cue 2 Beats voraus
    #expect(near(l.start, 4.5) && near(l.end, 6.5))
    #expect(near(l.pos, 3.5))   // kein Sprung, die Position läuft hinein
}

@Test func loopSnapTakesPassedLoopCue() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    let l = loopAt(c, 5.0)   // Loop-Cue vor 1 Beat überspielt
    #expect(near(l.start, 4.5) && near(l.end, 6.5))
    #expect(near(l.pos, 5.0) && l.pos > l.start && l.pos < l.end)
}

@Test func loopSnapTakesHotcueLoopAndItsLength() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    let l = loopAt(c, 19.5)   // Hotcue 5 (2 Beats) 1,5 Beats voraus
    #expect(near(l.start, 20.25) && near(l.end, 21.25))
    #expect(c.snapshot().decks[0].loopSize == 2)
}

@Test func loopSnapOnPhraseBoundary() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    let after = loopAt(c, 8.25)   // 0,5 Beats nach der 4-Takt-Grenze
    #expect(near(after.start, 8.0) && near(after.end, 10.0) && near(after.pos, 8.25))
    c.exitLoop(0)
    let before = loopAt(c, 15.8)   // 0,4 Beats vor der Grenze bei 16 s: Loop beginnt dort
    #expect(near(before.start, 16.0) && near(before.end, 18.0) && near(before.pos, 15.8))
}

@Test func loopSnapFarFromBothUsesBeatSnap() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    let l = loopAt(c, 11.3)
    #expect(near(l.start, 11.0) && near(l.end, 13.0))
}

@Test func loopSnapOffKeepsOldBehaviour() async throws {
    let (c, url) = try await controller(snap: false)
    defer { try? FileManager.default.removeItem(at: url) }
    let cue = loopAt(c, 5.3)
    #expect(near(cue.start, 5.0) && near(cue.end, 7.0))
    c.exitLoop(0)
    let phrase = loopAt(c, 15.8)
    #expect(near(phrase.start, 15.5) && near(phrase.end, 17.5))
}

@Test func loopSnapSwitchesAndWindows() async throws {
    let (c, url) = try await controller { $0.loopSnapCues = false; $0.loopSnapPhraseBeats = 2 }
    defer { try? FileManager.default.removeItem(at: url) }
    let cue = loopAt(c, 5.3)   // Loop-Cues aus -> Beat-Snap
    #expect(near(cue.start, 5.0))
    c.exitLoop(0)
    let phrase = loopAt(c, 7.1)   // 1,8 Beats vor der Grenze, Toleranz 2
    #expect(near(phrase.start, 8.0))
}

@Test func loopInSnaps() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.seek(0, seconds: 8.3)
    c.setLoopIn(0)
    #expect(c.snapshot().decks[0].loopIn.map { near($0, 8.0) } == true)
    c.seek(0, seconds: 4.0)
    c.setLoopIn(0)   // Loop-Cue 1 Beat voraus: wird als Loop übernommen
    let s = c.snapshot().decks[0]
    #expect(s.loopActive && s.loopIn.map { near($0, 4.5) } == true)
    #expect(near(c.engine.loop(0).end, 6.5) && near(c.position(0), 4.0))
}
