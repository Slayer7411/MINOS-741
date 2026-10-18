import AVFoundation
import Foundation
import Testing
import MixCore
@testable import MixEngine
@testable import MixApp

// Lade-Schutz und LOAD am Controller: Reports offline durch ControllerManager + MixController (kein Gerät, kein Audio).

private func silentWAV(seconds: Double) throws -> URL {
    let rate = 44100.0
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-load-\(UUID().uuidString).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(seconds * rate))!
    buf.frameLength = buf.frameCapacity
    try file.write(from: buf)
    return url
}

/// Report 0x01: Byte 0x14 = Shift 0x04, LOAD links 0x08, LOAD rechts 0x02
private func report(loadLeft: Bool = false, loadRight: Bool = false, shift: Bool = false) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 32)
    r[0] = 0x01
    r[0x14] = (shift ? 0x04 : 0) | (loadLeft ? 0x08 : 0) | (loadRight ? 0x02 : 0)
    return r
}

@MainActor
private final class LoadRig {
    let core = testController()
    let manager: ControllerManager
    let unit: ControllerUnit
    let url: URL
    /// angekommene LOADs: (Deck, erzwungen)
    var loads: [(deck: Int, force: Bool)] = []

    init() async throws {
        url = try silentWAV(seconds: 20)
        var t = Track(key: url.path, path: url.path)
        t.bpm = 120
        t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
        core.load(t, deck: 0)
        core.load(t, deck: 1)
        let loadDeadline = Date().addingTimeInterval(60)
        while (core.trackAudio(0) == nil || core.trackAudio(1) == nil), Date() < loadDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(core.trackAudio(0) != nil && core.trackAudio(1) != nil)
        manager = ControllerManager(core: core, status: ControllerStatus())
        unit = ControllerUnit(device: nil, info: .init(id: "L", location: 0, left: 0, right: 1), manager: manager)
        unit.parse(report())
        manager.onLoad = { [unowned self] _, d, force in loads.append((d, force)) }
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// LOAD drücken und loslassen, dann die Haupt-Queue laufen lassen (onLoad kommt dort an)
    func pressLoad(left: Bool, shift: Bool = false) async throws {
        unit.parse(report(loadLeft: left, loadRight: !left, shift: shift))
        unit.parse(report(shift: shift))
        unit.parse(report())
        try await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor @Test func controllerLoadIntoPlayingDeckIsBlocked() async throws {
    let rig = try await LoadRig()
    rig.core.togglePlay(0)
    #expect(rig.core.loadBlocked(0))
    try await rig.pressLoad(left: true)
    #expect(rig.loads.isEmpty)   // Deck A spielt: kein Load
    try await rig.pressLoad(left: false)
    #expect(rig.loads.count == 1 && rig.loads[0].deck == 1 && !rig.loads[0].force)   // Deck B steht: Load
}

@MainActor @Test func shiftLoadForcesIntoPlayingDeck() async throws {
    let rig = try await LoadRig()
    rig.core.togglePlay(0)
    try await rig.pressLoad(left: true, shift: true)
    #expect(rig.loads.count == 1 && rig.loads[0].deck == 0 && rig.loads[0].force)
}

@MainActor @Test func loadLockCanBeSwitchedOff() async throws {
    let rig = try await LoadRig()
    var p = EnginePrefs()
    p.loadProtection = false
    rig.core.setPrefs(p)
    rig.core.togglePlay(0)
    #expect(!rig.core.loadBlocked(0))
    try await rig.pressLoad(left: true)
    #expect(rig.loads.count == 1 && rig.loads[0].deck == 0)
}

@MainActor @Test func cueHeldCountsAsPlaying() async throws {
    let rig = try await LoadRig()
    rig.core.cueDown(0)   // am Cue: CUE gehalten spielt an
    #expect(rig.core.snapshot().decks[0].cueHeld)
    #expect(rig.core.loadBlocked(0))
    rig.core.cueUp(0)
    #expect(!rig.core.loadBlocked(0))
}

@MainActor @Test func shiftLoadAsInstantDouble() async throws {
    let rig = try await LoadRig()
    var p = ControllerPrefs()
    p.shiftLoad = .double
    rig.manager.prefs = p
    rig.core.seek(1, seconds: 5)
    rig.core.togglePlay(1)
    rig.core.shiftKey(1, 2)
    try await rig.pressLoad(left: true, shift: true)   // links = Deck A, Quelle = rechte Seite (B)
    #expect(rig.loads.isEmpty)
    let a = rig.core.snapshot().decks[0]
    #expect(a.playing && a.keyShift == 2)
    #expect(abs(rig.core.position(0) - rig.core.position(1)) < 1e-9)
    // A spielt jetzt: Lade-Schutz gilt auch für Doubles
    rig.core.shiftKey(1, 1)
    try await rig.pressLoad(left: true, shift: true)
    #expect(rig.core.snapshot().decks[0].keyShift == 2)
}
