import AVFoundation
import Foundation
import Testing
import MixCore
@testable import MixEngine
@testable import MixApp

// Rückgängig: Stapel (Grenze, Reihenfolge, Verschmelzen, Trackwechsel) und Deck-Aktionen gegen den Kern (offline, kein Gerät).
// Track: 120 BPM, Grid ab 0 -> Beat = 0,5 s.

private func silentWAV(seconds: Double) throws -> URL {
    let rate = 44100.0
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-undo-\(UUID().uuidString).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(seconds * rate))!
    buf.frameLength = buf.frameCapacity
    try file.write(from: buf)
    return url
}

@MainActor
private final class Rig {
    let core = testController()
    let stack = UndoStack()
    let rec: DeckUndoRecorder
    let url: URL

    init() async throws {
        url = try silentWAV(seconds: 40)
        var t = Track(key: url.path, path: url.path)
        t.bpm = 120
        t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
        core.load(t, deck: 0)
        let loadDeadline = Date().addingTimeInterval(60)
        while (core.trackAudio(0) == nil), Date() < loadDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(core.trackAudio(0) != nil)
        rec = DeckUndoRecorder(core: core, stack: stack)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var deck: DeckState { core.snapshot().decks[0] }
}

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-3) -> Bool { abs(a - b) < tol }

// MARK: - Stapel

@MainActor @Test func undoStackKeepsLastHundred() {
    let s = UndoStack()
    var value = 0
    for i in 1...150 {
        let old = value
        value = i
        s.record("\(i)", before: old, after: i) { b, a, undo in value = undo ? b : a }
    }
    #expect(s.done.count == UndoStack.limit)
    #expect(s.done.first?.label == "51")
    #expect(s.undoLabel == "150")
    #expect(s.undo() == "150" && value == 149)
    #expect(s.undo() == "149" && value == 148)
    #expect(s.redoLabel == "149")
    #expect(s.redo() == "149" && value == 149)
    // neuer Schritt verwirft Wiederherstellen
    s.record("x", before: value, after: 7) { b, a, undo in value = undo ? b : a }
    #expect(!s.canRedo && s.redo() == nil)
}

@MainActor @Test func undoStackCoalescesWithinWindow() {
    let s = UndoStack()
    var v = 0.0
    // Fader ziehen: drei Werte kurz hintereinander = ein Schritt, Vorher bleibt der erste
    for (i, x) in [1.0, 2.0, 3.0].enumerated() {
        let old = v
        v = x
        s.record("Tempo", coalesce: "tempo.0", now: 10 + Double(i) * 0.2, before: old, after: x) { b, a, undo in v = undo ? b : a }
    }
    #expect(s.done.count == 1)
    // nach Ablauf des Fensters: neuer Schritt
    let old = v
    v = 4
    s.record("Tempo", coalesce: "tempo.0", now: 20, before: old, after: 4.0) { b, a, undo in v = undo ? b : a }
    #expect(s.done.count == 2)
    s.undo()
    #expect(v == 3)
    s.undo()
    #expect(v == 0)
    s.redo()
    #expect(v == 3)
}

@MainActor @Test func undoStackClearsOnlyThatDeck() {
    let s = UndoStack()
    for d in [0, 1, 0, 2] { s.push(UndoEntry(label: "d\(d)", undo: {}, redo: {}, deck: d)) }
    s.push(UndoEntry(label: "browser", undo: {}, redo: {}))
    s.clear(deck: 0)
    #expect(s.done.map(\.label) == ["d1", "d2", "browser"])
    #expect(s.undoLabel == "browser")
}

@MainActor @Test func undoStackRecordsNothingWhileReplaying() {
    let s = UndoStack()
    var prep: [String] = []
    func edit(_ new: [String]) {
        let old = prep
        prep = new
        s.record("Preparation", before: old, after: new) { b, a, undo in edit(undo ? b : a) }
    }
    edit(["a"])
    edit(["a", "b"])
    #expect(s.done.count == 2)
    s.undo()
    #expect(prep == ["a"] && s.done.count == 1 && s.undone.count == 1)
    s.undo()
    #expect(prep == [] && s.done.isEmpty)
    s.redo(); s.redo()
    #expect(prep == ["a", "b"] && s.done.count == 2)
}

// MARK: - Deck

/// ein Kern für alle Deck-Fälle (weniger Last neben den anderen Kern-Tests)
@MainActor @Test func undoDeckActions() async throws {
    let rig = try await Rig()
    hotcueSetAndDelete(rig)
    loopAndBeatjump(rig)
    trimGridKeyTempo(rig)
    try await skipsAnotherTrack(rig)
}

@MainActor private func hotcueSetAndDelete(_ rig: Rig) {
    rig.core.seek(0, seconds: 4)
    rig.rec.edit(0, "Hotcue 3 setzen", .cues) { rig.core.hotcue(0, 2) }
    #expect(rig.deck.hotcues[2].map { near($0.startMs, 4000, 1) } == true)
    #expect(rig.stack.undoLabel == "Hotcue 3 setzen · Deck A")
    // Anspringen ändert keine Hotcues -> kein Eintrag
    rig.rec.edit(0, "Hotcue 3 setzen", .cues) { rig.core.hotcue(0, 2) }
    #expect(rig.stack.done.count == 1)
    rig.rec.edit(0, "Hotcue 3 löschen", .cues) { rig.core.hotcue(0, 2, delete: true) }
    #expect(rig.deck.hotcues[2] == nil)
    rig.stack.undo()
    #expect(rig.deck.hotcues[2] != nil)
    rig.stack.undo()
    #expect(rig.deck.hotcues[2] == nil)
    rig.stack.redo()
    #expect(rig.deck.hotcues[2] != nil)
    // Hotcue 6 danach am Controller gesetzt (nicht aufgezeichnet): Rückgängig nimmt nur Hotcue 3 zurück
    rig.core.seek(0, seconds: 6)
    rig.core.hotcue(0, 5)
    rig.stack.undo()
    #expect(rig.deck.hotcues[2] == nil && rig.deck.hotcues[5] != nil)
}

@MainActor private func loopAndBeatjump(_ rig: Rig) {
    rig.core.seek(0, seconds: 10)
    rig.rec.edit(0, "Loop setzen", [.loop, .position]) { rig.core.autoLoop(0, size: 4) }
    #expect(rig.deck.loopActive && rig.core.engine.loop(0).active)
    rig.stack.undo()
    #expect(!rig.deck.loopActive && !rig.core.engine.loop(0).active)
    rig.stack.redo()
    #expect(rig.deck.loopActive)
    rig.core.exitLoop(0)
    rig.core.seek(0, seconds: 10)
    rig.rec.edit(0, "Beatjump +8", [.position, .loop]) { rig.core.beatjump(0, beats: 8) }
    #expect(near(rig.core.position(0), 14))
    rig.stack.undo()
    #expect(near(rig.core.position(0), 10))
    rig.stack.redo()
    #expect(near(rig.core.position(0), 14))
}

@MainActor private func trimGridKeyTempo(_ rig: Rig) {
    rig.rec.edit(0, "Schnitt IN verschieben", [.trim, .loop]) { _ = rig.core.setTrimPoint(0, end: false, 5) }
    #expect(rig.deck.trim.start == 5)
    rig.stack.undo()
    #expect(rig.deck.trim.isEmpty)
    rig.core.seek(0, seconds: 1.25)
    rig.rec.edit(0, "Grid-Anker setzen", .grid) { rig.core.setGridAnchorHere(0) }
    #expect(rig.deck.grid.map { near($0.anchor, 1.25) } == true && rig.deck.gridEdited)
    rig.stack.undo()
    #expect(rig.deck.grid.map { near($0.anchor, 0) } == true && !rig.deck.gridEdited)
    // Key-Shift und Tempo
    rig.rec.edit(0, "Key-Shift +1", .key) { rig.core.shiftKey(0, 1) }
    rig.rec.edit(0, "Tempo", .tempo) { rig.core.setTempo(0, 4) }
    rig.stack.undo()
    #expect(rig.deck.tempoPct == 0 && rig.deck.keyShift == 1)
    rig.stack.undo()
    #expect(rig.deck.keyShift == 0)
}

@MainActor private func skipsAnotherTrack(_ rig: Rig) async throws {
    rig.core.seek(0, seconds: 2)
    rig.rec.edit(0, "Hotcue 1 setzen", .cues) { rig.core.hotcue(0, 0) }
    // anderer Track im Deck (ohne Abgleich über den Stapel): Rückgängig ändert nichts
    let other = try silentWAV(seconds: 20)
    defer { try? FileManager.default.removeItem(at: other) }
    var t = Track(key: other.path, path: other.path)
    t.bpm = 120
    rig.core.load(t, deck: 0)
    let loadDeadline = Date().addingTimeInterval(60)
    while (rig.deck.track?.key != other.path || rig.core.trackAudio(0) == nil), Date() < loadDeadline { try await Task.sleep(for: .milliseconds(20)) }
    rig.core.hotcue(0, 0)
    let cues = rig.deck.hotcues
    rig.stack.undo()
    #expect(rig.deck.hotcues == cues)
}
