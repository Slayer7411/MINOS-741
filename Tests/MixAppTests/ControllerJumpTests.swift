import AVFoundation
import Foundation
import Testing
import MixCore
import MixDSP
@testable import MixEngine
@testable import MixApp

// Controller-Reports offline durch ControllerManager + MixController (kein Gerät, kein Audiogerät).
// Track: 120 BPM, Grid ab 0 -> Beat = 0,5 s, Takt = 2 s.

private let beat = 0.5, bar = 2.0

/// stille Testdatei (Stereo, 44,1 kHz)
private func silentWAV(seconds: Double) throws -> URL {
    let rate = 44100.0
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-ctl-\(UUID().uuidString).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(seconds * rate))!
    buf.frameLength = buf.frameCapacity
    try file.write(from: buf)
    return url
}

/// Report 0x01: Bytes 0x14 (Shift 0x04), 0x15 (rechts), 0x16 (links)
private func report(left: UInt8 = 0, right: UInt8 = 0, shift: Bool = false) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 32)
    r[0] = 0x01
    r[0x14] = shift ? 0x04 : 0
    r[0x15] = right
    r[0x16] = left
    return r
}

private enum Bit {
    static let sync: UInt8 = 0x04, flux: UInt8 = 0x08, pad3: UInt8 = 0x20, pad4: UInt8 = 0x10
}

@MainActor
private final class Rig {
    let core = MixController()
    let manager: ControllerManager
    var units: [ControllerUnit] = []
    let url: URL

    init() async throws {
        url = try silentWAV(seconds: 40)
        var t = Track(key: url.path, path: url.path)
        t.bpm = 120
        t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
        core.load(t, deck: 0)
        core.load(t, deck: 1)
        let loadDeadline = Date().addingTimeInterval(60)
        while (core.trackAudio(0) == nil || core.trackAudio(1) == nil), Date() < loadDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(core.trackAudio(0) != nil && core.trackAudio(1) != nil)
        manager = ControllerManager(core: core, status: ControllerStatus())
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// neuer Controller: linke Seite = Deck `left`, rechte = Deck `right`; erster Report setzt nur den Vergleich
    func unit(left: Int, right: Int) -> ControllerUnit {
        let u = ControllerUnit(device: nil, info: .init(id: "T\(units.count)", location: units.count, left: left, right: right),
                               manager: manager)
        u.parse(report())
        units.append(u)
        return u
    }

    var deck0: DeckState { core.snapshot().decks[0] }
}

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) < tol }

// MARK: - Report → Ereignisse

@MainActor @Test func reportSequenceForSyncPadCombo() async throws {
    let rig = try await Rig()
    let u = rig.unit(left: 0, right: 1)
    // linke Seite: Sync runter, Pad 4 runter, Pad 4 hoch, Sync hoch
    #expect(u.decode(report(left: Bit.sync)) == [.sync(.left, true)])
    #expect(u.decode(report(left: Bit.sync | Bit.pad4)) == [.hotcue(.left, 3, true)])
    #expect(u.decode(report(left: Bit.sync)) == [.hotcue(.left, 3, false)])
    #expect(u.decode(report()) == [.sync(.left, false)])
    // beides im selben Report: Sync zuerst, dann das Pad
    #expect(u.decode(report(right: Bit.sync | Bit.pad3)) == [.sync(.right, true), .hotcue(.right, 2, true)])
    #expect(u.decode(report(right: Bit.sync | Bit.pad3)) == [])   // gleicher Report: nichts Neues
    #expect(u.decode(report()) == [.sync(.right, false), .hotcue(.right, 2, false)])
}

// MARK: - Sync gehalten + Pad 3/4: genau ein Takt

private enum Role: CaseIterable { case free, synced, master }
private enum Layer: CaseIterable { case none, latched, fluxHotcues, fluxBeatjump }

private struct Case: CustomStringConvertible {
    var playing: Bool, role: Role, loop: Bool, snapQuant: Bool, layer: Layer
    var description: String { "playing \(playing) · \(role) · loop \(loop) · snap/quant \(snapQuant) · \(layer)" }
}

private let allCases: [Case] = [false, true].flatMap { playing in
    Role.allCases.flatMap { role in
        [false, true].flatMap { loop in
            [false, true].flatMap { sq in Layer.allCases.map { Case(playing: playing, role: role, loop: loop, snapQuant: sq, layer: $0) } }
        }
    }
}

/// Deck A auf einen Ausgangszustand bringen (Deck B = Gegenspieler bei 20 s)
@MainActor
private func prepare(_ rig: Rig, _ c: Case) {
    let core = rig.core
    for d in 0..<2 {
        let s = core.snapshot().decks[d]
        if s.loopActive { core.exitLoop(d) }
        if s.sync { core.toggleSync(d) }
        if s.playing { core.togglePlay(d) }
        for n in [2, 3, 6, 7] { core.hotcue(d, n, delete: true) }
    }
    if let m = core.snapshot().masterDeck { core.toggleMaster(m) }
    var p = EnginePrefs()
    p.snap = c.snapQuant; p.quantize = c.snapQuant
    core.setPrefs(p)
    core.seek(0, seconds: 10.25)   // Beat 20,5: bewusst zwischen zwei Beats
    core.seek(1, seconds: 20.0)
    switch c.role {
    case .free: break
    case .synced: core.toggleMaster(1); core.toggleSync(0)
    case .master: core.toggleMaster(0); core.toggleSync(1)
    }
    if c.playing { core.togglePlay(1); core.togglePlay(0) }
    if c.loop { core.autoLoop(0, size: 16) }
}

/// Ziel eines Taktsprungs: ±2 s, im Loop umlaufend
@MainActor
private func expected(_ rig: Rig, from p: Double, bars: Int) -> Double {
    var t = p + Double(bars) * beat   // Sync + Pad = ein Beat
    if rig.deck0.loopActive {
        let l = rig.core.engine.loop(0), len = l.end - l.start
        t = l.start + (t - l.start).truncatingRemainder(dividingBy: len)
        if t < l.start { t += len }
    }
    return t
}

@MainActor @Test func syncHeldPadJumpsExactlyOneBar() async throws {
    let rig = try await Rig()
    var prefs = ControllerPrefs()
    for c in allCases {
        prepare(rig, c)
        prefs.fluxPads = c.layer == .fluxBeatjump ? .beatjump : .hotcues
        prefs.fluxBeatjumpBeats = 1
        rig.manager.prefs = prefs
        let u = rig.unit(left: 0, right: 1)
        var hold: UInt8 = 0
        switch c.layer {
        case .none: break
        case .latched:
            u.parse(report(left: Bit.flux)); u.parse(report())   // Flux antippen: Pad-Ebene 5–8 rastet ein
            #expect(u.layerOn(.left, prefs), "\(c)")
        case .fluxHotcues, .fluxBeatjump:
            hold = Bit.flux; u.parse(report(left: hold))
        }
        let syncBefore = rig.deck0.sync, layerBefore = u.padLayer[.left]
        for (pad, bars) in [(Bit.pad4, 1), (Bit.pad3, -1), (Bit.pad3, -1), (Bit.pad4, 1)] {
            let from = rig.core.position(0), want = expected(rig, from: from, bars: bars)
            u.parse(report(left: hold | Bit.sync))
            u.parse(report(left: hold | Bit.sync | pad))
            u.parse(report(left: hold | Bit.sync))
            u.parse(report(left: hold))
            #expect(near(rig.core.position(0), want), "\(c) · \(bars): \(from) -> \(rig.core.position(0)), soll \(want)")
        }
        u.parse(report())
        // Steuertakt (Phasen-Lock, harter Sprung nach 20 Takten) darf nichts mehr verschieben
        let settled = rig.core.position(0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(near(rig.core.position(0), settled), "\(c): Steuertakt verschiebt \(settled) -> \(rig.core.position(0))")
        #expect(rig.deck0.sync == syncBefore, "\(c): Sync umgeschaltet")
        #expect(u.padLayer[.left] == layerBefore, "\(c): Pad-Ebene umgeschaltet")
        #expect([2, 3, 6, 7].allSatisfy { rig.deck0.hotcues[$0] == nil }, "\(c): Hotcue gesetzt")
        if c.role == .master || c.role == .synced, c.playing {
            #expect(near(rig.core.phaseError(c.role == .master ? 1 : 0) ?? 1, 0, 1e-6), "\(c): Phase")
        }
    }
}

/// Sync antippen schaltet weiter Sync; Pad 3/4 ohne Sync = Hotcue
@MainActor @Test func syncTapAndPadsWithoutSync() async throws {
    let rig = try await Rig()
    let u = rig.unit(left: 0, right: 1)
    prepare(rig, Case(playing: false, role: .free, loop: false, snapQuant: true, layer: .none))
    u.parse(report(left: Bit.sync)); u.parse(report())
    #expect(rig.deck0.sync)
    u.parse(report(left: Bit.pad4)); u.parse(report())
    #expect(rig.deck0.hotcues[3] != nil)
    #expect(near(rig.core.position(0), 10.25))
}

/// zwei Controller: Sync auf dem einen macht die Pads des anderen nicht zum Taktsprung, jedes Deck springt für sich
@MainActor @Test func twoControllersStaySeparate() async throws {
    let rig = try await Rig()
    prepare(rig, Case(playing: true, role: .synced, loop: false, snapQuant: true, layer: .none))
    let a = rig.unit(left: 0, right: 1), b = rig.unit(left: 1, right: 0)
    let p0 = rig.core.position(0), p1 = rig.core.position(1)
    b.parse(report(left: Bit.sync))                  // B hält Sync für Deck B
    a.parse(report(left: Bit.pad4)); a.parse(report())   // A: Pad 4 auf Deck A = Hotcue 4 setzen, kein Sprung
    #expect(near(rig.core.position(0), p0) && rig.deck0.hotcues[3] != nil)
    b.parse(report(left: Bit.sync | Bit.pad4)); b.parse(report(left: Bit.sync)); b.parse(report())
    #expect(near(rig.core.position(1), p1 + beat))
    #expect(near(rig.core.position(0), p0))
    #expect(rig.core.snapshot().decks[1].sync == false)   // Kombination benutzt: Sync bleibt aus
    // rechte Seite von B steuert ebenfalls Deck A
    b.parse(report(right: Bit.sync)); b.parse(report(right: Bit.sync | Bit.pad3)); b.parse(report())
    #expect(near(rig.core.position(0), p0 - beat))
}

// MARK: - mit Render: laufende Decks, Keylock, Phasen-Lock

/// Phasen-Lock aus: der Sprung selbst hält die Phase. An: der Lock zieht höchstens weich nach (Steuertakt läuft
/// in Echtzeit, der Kern hier schneller -> kleiner Nachlauf möglich), fügt aber keinen Takt hinzu und nimmt keinen weg
@MainActor @Test(arguments: [false, true]) func barJumpWhilePlayingStaysInPhase(phaseLock: Bool) async throws {
    let rig = try await Rig()
    let core = rig.core
    var p = EnginePrefs(); p.phaseLock = phaseLock
    core.setPrefs(p)
    let u = rig.unit(left: 0, right: 1)
    let fs = core.engine.sampleRate, block = 512
    var l = [Float](repeating: 0, count: block), r = [Float](repeating: 0, count: block)
    /// Echtzeitkern blockweise rechnen; liefert die gerechnete Zeit
    func render(_ secs: Double) -> Double {
        let n = Int(secs * fs / Double(block))
        for _ in 0..<n {
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    var ptrs: [UnsafeMutablePointer<Float>?] = [lp.baseAddress, rp.baseAddress]
                    ptrs.withUnsafeMutableBufferPointer { mdsp_render(core.engine.core, $0.baseAddress, 2, Int32(block)) }
                }
            }
        }
        return Double(n * block) / fs
    }
    core.seek(0, seconds: 10.25); core.seek(1, seconds: 20)
    core.toggleMaster(1)
    core.togglePlay(1); _ = render(0.2)
    core.toggleSync(0); core.togglePlay(0); _ = render(0.3)
    #expect(core.snapshot().decks[0].keylock)
    let tol = phaseLock ? 0.1 : 0.01
    for (pad, bars) in [(Bit.pad4, 1), (Bit.pad3, -1), (Bit.pad4, 1), (Bit.pad3, -1)] {
        let from = core.position(0)
        u.parse(report(left: Bit.sync)); u.parse(report(left: Bit.sync | pad))
        var ran = render(0.2)
        try await Task.sleep(for: .milliseconds(150))   // Steuertakt läuft mit
        u.parse(report(left: Bit.sync)); u.parse(report())
        ran += render(0.3)
        let moved = (core.position(0) - from - ran) / beat
        #expect(abs(moved - Double(bars)) < tol, "\(bars): \(moved) Beats")   // Sync + Pad = ein Beat
        #expect(abs(core.phaseError(0) ?? 1) < tol, "\(bars): Phase \(core.phaseError(0) ?? .nan)")
        #expect(core.snapshot().decks[0].sync)
    }
}
