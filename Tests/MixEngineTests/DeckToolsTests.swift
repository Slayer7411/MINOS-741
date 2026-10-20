import Foundation
import Testing
import MixCore
import MixDSP
@testable import MixEngine

/// Key Sync, Instant Doubles, Active Loop im Steuerkern ohne Audiogerät.
/// 120 BPM, Grid ab 0 -> Beat = 0,5 s; Datei 24 s.
private func controller(keys: [Int] = [21, 9], cues: [Cue] = [], _ edit: (inout EnginePrefs) -> Void = { _ in }) async throws -> (MixController, URL) {
    let url = try writeWAV(rate: 44100, channels: 2, seconds: 24)
    let c = testController()
    var p = testPrefs()
    edit(&p)
    c.setPrefs(p)
    for (d, k) in keys.enumerated() {
        var t = Track(key: url.path, path: url.path)
        t.bpm = 120
        t.musicalKey = k
        t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)] + cues
        c.load(t, deck: d)
    }
    try await awaitLoaded(c, decks: Array(keys.indices))
    #expect(keys.indices.allSatisfy { c.trackAudio($0) != nil })
    return (c, url)
}

@Test func keySyncShiftsToMasterAndTurnsKeylockOn() async throws {
    let (c, url) = try await controller { $0.keylockDefault = false }
    defer { try? FileManager.default.removeItem(at: url) }
    c.toggleMaster(1)
    #expect(!c.snapshot().decks[0].keylock)
    c.keySync(0)   // 1m -> 4d (A): Parallele 4m = −3
    let s = c.snapshot().decks[0]
    #expect(s.keylock && s.keyShift == -3)
    // Master ohne Keylock +6 % Tempo ≈ +1 Halbton: 4d -> 11d, Parallele 11m = 1m − 2
    c.setTempo(1, 6)
    c.keySync(0)
    #expect(c.snapshot().decks[0].keyShift == -2)
}

@Test func keySyncWithoutMasterChangesNothing() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.toggleMaster(0)
    c.keySync(0)   // Deck ist selbst Master
    #expect(c.snapshot().decks[0].keyShift == 0)
}

@Test func instantDoubleTakesStateAndPosition() async throws {
    let (c, url) = try await controller()
    defer { try? FileManager.default.removeItem(at: url) }
    c.seek(1, seconds: 6.25)
    c.togglePlay(1)
    c.shiftKey(1, 2)
    c.setTempo(1, 3)
    c.autoLoop(1, size: 4)
    #expect(c.instantDouble(from: 1, to: 0))
    let a = c.snapshot().decks[0], b = c.snapshot().decks[1]
    #expect(a.track?.key == b.track?.key && a.playing && c.engine.player(0).playing)
    #expect(a.keyShift == 2 && a.tempoPct == 3 && a.keylock == b.keylock && a.loopActive && a.loopSize == 4)
    let la = c.engine.loop(0), lb = c.engine.loop(1)
    #expect(la.active && la.start == lb.start && la.end == lb.end)
    #expect(abs(c.position(0) - c.position(1)) < 1e-9)
    #expect(c.trackAudio(0) === c.trackAudio(1))   // dieselben Audiodaten, kein Laden
    // Lade-Schutz: Ziel spielt jetzt -> nichts, mit force -> wieder
    c.shiftKey(1, 1)
    #expect(!c.instantDouble(from: 1, to: 0))
    #expect(c.snapshot().decks[0].keyShift == 2)
    #expect(c.instantDouble(from: 1, to: 0, force: true))
    #expect(c.snapshot().decks[0].keyShift == 3)
}

@Test func instantDoubleNeedsLoadedSource() async throws {
    let (c, url) = try await controller(keys: [21])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(!c.instantDouble(from: 1, to: 0))   // Deck B leer
    #expect(!c.instantDouble(from: 0, to: 0))
    #expect(c.instantDouble(from: 0, to: 2))
    #expect(c.snapshot().decks[2].track != nil && !c.snapshot().decks[2].playing)
}

// MARK: - Active Loop (Position über ausstehende Sprünge, Steuertakt 200 Hz)

private let loopCue = Cue(name: "Loop", kind: .loop, startMs: 4500, lengthMs: 2000, hotcue: 4)

private func activeLoopController(_ mode: ActiveLoopMode = .always) async throws -> (MixController, URL) {
    let url = try writeWAV(rate: 44100, channels: 2, seconds: 24)
    let c = testController()
    var p = testPrefs()
    p.activeLoopMode = mode
    c.setPrefs(p)
    var t = Track(key: url.path, path: url.path)
    t.bpm = 120
    t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1), loopCue]
    c.load(t, deck: 0, activeLoops: [4, 2])   // 2: kein Hotcue -> fällt weg
    try await awaitLoaded(c)
    #expect(c.snapshot().decks[0].activeLoops == [4])
    return (c, url)
}

/// springen, zwei Steuertakte+ warten, Loop-Zustand
private func at(_ c: MixController, _ t: Double) async throws -> Bool {
    c.seek(0, seconds: t)
    try await Task.sleep(for: .milliseconds(40))
    return c.snapshot().decks[0].loopActive
}

@Test func activeLoopEngagesWhenReached() async throws {
    let (c, url) = try await activeLoopController()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try await !at(c, 4.47))   // steht: nichts
    c.togglePlay(0)
    try await Task.sleep(for: .milliseconds(40))
    var l = c.engine.loop(0)
    #expect(l.active && abs(l.start - 4.5) < 1e-9 && abs(l.end - 6.5) < 1e-9)
    #expect(abs(c.position(0) - 4.47) < 1e-9)   // kein Sprung: die Position läuft hinein
    // Loop-Taste verlässt ihn, im Loop greift er nicht wieder
    c.autoLoop(0)
    #expect(try await !at(c, 5.0))
    // nächster Durchlauf: wieder davor, dann am Anfang
    #expect(try await !at(c, 3.0))
    #expect(try await at(c, 4.5))
    c.exitLoop(0)
    // hineingesprungen (weit hinter dem Anfang): greift nicht
    #expect(try await !at(c, 3.0))
    #expect(try await !at(c, 5.5))
    // rückwärts: greift nicht
    #expect(try await !at(c, 3.0))
    c.setReverse(0, true)
    #expect(try await !at(c, 4.5))
    c.setReverse(0, false)
    // aus: greift nicht mehr
    c.toggleActiveLoop(0, 4)
    #expect(try await !at(c, 3.0))
    #expect(try await !at(c, 4.5))
    l = c.engine.loop(0)
    #expect(!l.active)
}

@Test func activeLoopOnceMode() async throws {
    let (c, url) = try await activeLoopController(.once)
    defer { try? FileManager.default.removeItem(at: url) }
    c.togglePlay(0)
    #expect(try await at(c, 4.5))
    c.exitLoop(0)
    #expect(try await !at(c, 3.0))
    #expect(try await !at(c, 4.5))   // einmal je Laden
}

@Test func activeLoopFollowsHotcueChanges() async throws {
    let (c, url) = try await activeLoopController()
    defer { try? FileManager.default.removeItem(at: url) }
    c.hotcue(0, 4, delete: true)
    #expect(c.snapshot().decks[0].activeLoops.isEmpty)
    c.hotcue(0, 1)   // normaler Cue: kein Active Loop möglich
    c.toggleActiveLoop(0, 1)
    #expect(c.snapshot().decks[0].activeLoops.isEmpty)
}

/// Kern offline in Echtzeit-Takt: der Steuertakt schaltet vor dem Anfang ein, der Kern springt am Loop-Ende zurück
@Test func activeLoopWrapsInTheCore() async throws {
    let (c, url) = try await activeLoopController()
    defer { try? FileManager.default.removeItem(at: url) }
    let n = 512
    let bufs = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
    defer { bufs.forEach { $0.deallocate() } }
    var chans: [UnsafeMutablePointer<Float>?] = bufs
    c.seek(0, seconds: 4.2)
    c.togglePlay(0)
    var maxPos = 0.0
    let blocks = Int(2.8 * c.engine.sampleRate / Double(n))   // 4,2 s + 2,8 s = 7 s ohne Loop
    for _ in 0..<blocks {
        chans.withUnsafeMutableBufferPointer { mdsp_render(c.engine.core, $0.baseAddress, 2, Int32(n)) }
        maxPos = max(maxPos, c.position(0))
        try await Task.sleep(for: .milliseconds(Int(Double(n) / c.engine.sampleRate * 1000)))
    }
    #expect(c.snapshot().decks[0].loopActive)
    #expect(maxPos < 6.5 + 1e-3)                          // nie über das Loop-Ende
    #expect(c.position(0) >= 4.5 && c.position(0) < 6.5)  // läuft im Loop um
}
