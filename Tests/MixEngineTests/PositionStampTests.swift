import Foundation
import Testing
import MixDSP

/// Stempel der Position (mdsp_position_stamp): die Geschwindigkeit ist die, mit der der Kern den letzten Block
/// tatsächlich gerechnet hat (Nudge und Bend stecken in MD_RATE), nicht ein Wert aus der Anzeige.
private final class StampDeck {
    let e: OpaquePointer
    let fs = 44100.0
    let frames = 44100 * 20
    let n = 512
    let buf: UnsafeMutablePointer<Float>

    init(start: Double, playing: Bool) {
        e = mdsp_create(fs)
        buf = .allocate(capacity: frames)
        for i in 0..<frames { buf[i] = sin(Float(i) * 0.05) * 0.5 }
        mdsp_set_param(e, 0, MD_VOLUME, 1)
        mdsp_set_param(e, 0, MD_RATE, 1)
        mdsp_set_param(e, 0, MD_OUT_CHANNEL, 0)
        mdsp_set_track(e, 0, buf, buf, Int64(frames), fs, start)
        mdsp_set_param(e, 0, MD_PLAYING, playing ? 1 : 0)
    }
    deinit { mdsp_destroy(e); buf.deallocate() }

    /// einen Block rechnen; die Host-Zeit setzt der CoreAudio-Callback vor jedem Block
    func render() {
        mdsp_set_render_host(e, mach_absolute_time())
        let ptrs = (0..<4).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { ptrs.forEach { $0.deallocate() } }
        var chans: [UnsafeMutablePointer<Float>?] = ptrs
        chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 4, Int32(n)) }
    }

    func stamp() -> (pos: Double, speed: Double)? {
        var p = 0.0, h: UInt64 = 0, v = 0.0
        guard mdsp_position_stamp(e, 0, &p, &h, &v) else { return nil }
        return (p, v)
    }
}

@Test func positionStampCarriesTheAppliedRateWithNudgeAndBend() {
    // Tempo 100 % + Nudge 3 % + Bend 2 % = 1.05 (so setzt es der Controller in MD_RATE)
    let k = StampDeck(start: 10, playing: true)
    mdsp_set_param(k.e, 0, MD_RATE, 1.05)
    k.render()
    let a = k.stamp()
    k.render()
    let b = k.stamp()
    #expect(a != nil && b != nil)
    #expect(abs((b?.speed ?? 0) - 1.05) < 1e-6)
    // die gemeldete Position läuft mit genau dieser Geschwindigkeit
    if let a, let b { #expect(abs((b.pos - a.pos) / (512 / k.fs) - 1.05) < 1e-4) }
}

@Test func positionStampCarriesTheAppliedRateWithKeylockAndReverse() {
    let k = StampDeck(start: 10, playing: true)
    mdsp_set_param(k.e, 0, MD_RATE, 1.05)
    mdsp_set_param(k.e, 0, MD_KEYLOCK, 1)
    k.render()
    k.render()
    #expect(abs((k.stamp()?.speed ?? 0) - 1.05) < 1e-6)
    // rückwärts: Vorzeichen mit im Stempel
    mdsp_set_param(k.e, 0, MD_REVERSE, 1)
    k.render()
    #expect(abs((k.stamp()?.speed ?? 0) + 1.05) < 1e-6)
}

@Test func positionStampIsZeroWhenTheDeckStands() {
    let k = StampDeck(start: 10, playing: false)
    k.render()
    k.render()
    let s = k.stamp()
    #expect(s != nil)
    #expect(s?.speed == 0)
}

@Test func positionStampFollowsTheHandWhileScratching() {
    let k = StampDeck(start: 10, playing: false)
    k.render()
    mdsp_scratch(k.e, 0, 9.5, true)   // Hand zieht zurück: Geschwindigkeit negativ, solange sie zieht
    k.render()
    #expect((k.stamp()?.speed ?? 0) < 0)
}
