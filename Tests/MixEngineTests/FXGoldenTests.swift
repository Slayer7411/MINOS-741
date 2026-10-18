import AudioToolbox
import Foundation
import Testing
import MixDSP
@testable import MixEngine

// Bitgleich zum Stand vor den Insert-Slots: Prüfsummen der Ausgabe je Szenario, aufgenommen mit a3b680b (Gruppe/Single).
// Eingang = alte Sitzungs-JSON der Unit; sie wird zu Slots übernommen (FXMigration) und gerechnet.

private let fs = 48000.0
private let block = 512

private func fnv(_ h: inout UInt64, _ v: Float) {
    var x = v.bitPattern
    for _ in 0..<4 { h = (h ^ UInt64(x & 0xff)) &* 0x100000001b3; x >>= 8 }
}

/// Szenario: Folge (alte FX-JSON, Blöcke) auf FX 1 / Deck A, Rauschen, 125 BPM
private func run(_ steps: [(String, Int)], fdn: Bool = false) throws -> UInt64 {
    let eng = MixEngine(rate: fs)
    let e = eng.core
    let frames = Int(fs * 6)
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { l.deallocate(); r.deallocate() }
    var seed: UInt32 = 4711
    for i in 0..<frames {
        seed = seed &* 1664525 &+ 1013904223; l[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6
        seed = seed &* 1664525 &+ 1013904223; r[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6
    }
    mdsp_set_track(e, 0, l, r, Int64(frames), fs, 0)
    mdsp_set_param(e, 0, MD_KEYLOCK, 0)
    mdsp_set_param(e, 0, MD_PLAYING, 1)
    mdsp_clock_set_bpm(e, 125)
    mdsp_clock_set_beat(e, 0)
    var h: UInt64 = 0xcbf29ce484222325
    var bufs: [UnsafeMutablePointer<Float>?] = [.allocate(capacity: block), .allocate(capacity: block)]
    defer { bufs.forEach { $0?.deallocate() } }
    for (json, n) in steps {
        let fx = try JSONDecoder().decode(FXUnitState.self, from: Data(json.utf8))
        eng.setRack(unit: 0, deck: 0, kinds: fx.slots.map { $0.effect?.kind ?? 0 }, plugins: [])
        eng.applyFX(unit: 0, deck: 0, fx, assigned: true, bpm: 125, feedback: 0.45, filterResonance: 0.4,
                    reverbLevel: 1, reverbBrightness: 0.6, reverbPreDelay: 0.015, reverbFDN: fdn)
        for _ in 0..<n {
            bufs.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(block)) }
            for i in 0..<block { fnv(&h, bufs[0]![i]); fnv(&h, bufs[1]![i]) }
        }
    }
    return h
}

private func group(_ on: [Bool], _ amt: [Double], types: [Int] = [0, 1, 2], dw: Double = 1, delay: Int = 2, size: Double = 0.7) -> String {
    let slots = zip(on, amt).map { "{\"on\":\($0),\"amount\":\($1)}" }.joined(separator: ",")
    return "{\"single\":false,\"slots\":[\(slots)],\"slotTypes\":\(types),\"dryWet\":\(dw),\"delayIndex\":\(delay),\"reverbSize\":\(size)}"
}

private func single(_ type: Int, on: Bool, p: [Double] = [0.5, 0.45, 0.6], dw: Double = 1, opts: String = "{}") -> String {
    "{\"single\":true,\"singleType\":\(type),\"singleOn\":\(on),\"params\":\(p),\"dryWet\":\(dw),\"opts\":\(opts)}"
}

/// Szenario, Schritte (alte JSON, Blöcke), FDN-Hall
let fxGoldenScenarios: [(String, [(String, Int)], Bool)] = [
    ("group", [(group([true, true, true], [0.3, 0.7, 0.6]), 60), (group([true, false, true], [0.8, 0.7, 0.6]), 40),
               (group([false, false, false], [0.8, 0.7, 0.6]), 60)], false),
    ("group-dw", [(group([true, true, true], [0.3, 0.7, 0.6], dw: 0.6), 60), (group([true, true, false], [0.3, 0.7, 0.6], dw: 0.6), 40)], false),
    ("group-gater", [(group([true, true, true], [0.7, 0.7, 0.5], types: [0, 4, 2]), 60), (group([false, false, false], [0.7, 0.7, 0.5], types: [0, 4, 2]), 30)], false),
    ("filter", [(single(0, on: true, p: [0.25, 0.6, 0.5], dw: 0.9), 40), (single(0, on: false, p: [0.25, 0.6, 0.5], dw: 0.9), 20)], false),
    ("delay", [(single(1, on: true, p: [0.3, 0.6, 0.4], dw: 0.8), 60), (single(1, on: false, p: [0.3, 0.6, 0.4], dw: 0.8), 60)], false),
    ("reverb", [(single(2, on: true, p: [0.7, 0.3, 0.8], dw: 0.9), 60), (single(2, on: true, p: [0.7, 0.3, 0.8], dw: 0), 30),
                (single(2, on: false, p: [0.7, 0.3, 0.8], dw: 0), 40)], false),
    ("reverb-fdn", [(single(2, on: true, p: [0.6, 0.0, 1.0], dw: 1), 60), (single(2, on: false, p: [0.6, 0.0, 1.0], dw: 1), 40)], true),
    ("gater", [(single(4, on: true, opts: "{\"GATER.trip\":1}"), 60), (single(4, on: false, opts: "{\"GATER.trip\":1}"), 20)], false),
    ("roll", [(single(5, on: true, opts: "{\"ROLL.filter\":0.3}"), 60), (single(5, on: false, opts: "{\"ROLL.filter\":0.3}"), 20)], false),
    ("flanger", [(single(6, on: true), 60), (single(6, on: false), 20)], false),
    ("phaser", [(single(7, on: true, opts: "{\"PHASER.stages\":1}"), 60), (single(7, on: false, opts: "{\"PHASER.stages\":1}"), 20)], false),
]

/// Prüfsummen, aufgenommen mit a3b680b (vor den Insert-Slots)
/// neu 2026-10-16: Gleitregler springen aufs Ziel (Deck-Ausgang bit-genau), alle Pfade gleich verschoben
/// plugin neu 2026-10-18 (9f8fd46 hatte ihn nicht): gleicher Snap auf volSm, Abweichung zur alten Kette nur ab Block 9
/// (Frame 341), max. 4,99e-5 relativ (< kSnap). Ohne Snap der alte Hash 0xb633b06914920918
private let fxGoldenHashes: [String: UInt64] = [
    "group": 0x8c8046fe2ee78064, "group-dw": 0x6b9eddc55d9c346c, "group-gater": 0x7324c2d53c6c5ee2, "filter": 0x5464d7a0b342b2a3,
    "delay": 0xf544da8cca638ec, "reverb": 0x4206d0271bf767a6, "reverb-fdn": 0x1879204139f57e9a, "gater": 0xeafe3883598d2efe,
    "roll": 0x4ea489239746dcd0, "flanger": 0xfe3e34006749f04e, "phaser": 0x9ac9d6f42748d5e4, "plugin": 0x6f8a07943193ddbf,
]

/// Vorlage „Gruppe“ (aus GRP) und Einzel-Slot (aus SNGL) rechnen bitgleich wie vorher, über alle Blöcke
@Test(arguments: fxGoldenScenarios.map(\.0))
func fxSlotsBitIdenticalToOldModes(_ name: String) throws {
    let (_, steps, fdn) = try #require(fxGoldenScenarios.first { $0.0 == name })
    let h = try run(steps, fdn: fdn)
    #expect(h == fxGoldenHashes[name], "\(name): \(String(h, radix: 16))")
}

private func fcc(_ s: String) -> UInt32 { s.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }

/// ein Plugin (Apple-Tiefpass 300 Hz) auf FX 1 / Deck A: an mit D/W 0,6, dann aus (Fahne)
func fxGoldenPlugin(_ setup: (OpaquePointer, OpaquePointer, _ on: Bool) -> Void) throws -> UInt64 {
    let e = mdsp_create(fs)!
    defer { mdsp_destroy(e) }
    let frames = Int(fs * 3)
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { l.deallocate(); r.deallocate() }
    var seed: UInt32 = 99
    for i in 0..<frames {
        seed = seed &* 1664525 &+ 1013904223; l[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6
        seed = seed &* 1664525 &+ 1013904223; r[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6
    }
    mdsp_set_track(e, 0, l, r, Int64(frames), fs, 0)
    mdsp_set_param(e, 0, MD_KEYLOCK, 0)
    mdsp_set_param(e, 0, MD_PLAYING, 1)
    mdsp_set_param(e, 0, MD_FX1_ASSIGN, 1)
    var err = [CChar](repeating: 0, count: 256)
    let p = try #require(mdplug_open(fcc("aufx"), fcc("lpas"), fcc("appl"), fs, UInt32(MDSP_MAX_FRAMES), &err, Int32(err.count)))
    defer { mdplug_close(p) }
    AudioUnitSetParameter(AudioUnit(OpaquePointer(mdplug_audio_unit(p)!)), 0, kAudioUnitScope_Global, 0, 300, 0)
    mdsp_set_fx(e, 0, MDFX_DRYWET, 0.6)
    var h: UInt64 = 0xcbf29ce484222325
    var bufs: [UnsafeMutablePointer<Float>?] = [.allocate(capacity: block), .allocate(capacity: block)]
    defer { bufs.forEach { $0?.deallocate() } }
    for on in [true, false] {
        setup(e, p, on)
        for _ in 0..<30 {
            bufs.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(block)) }
            for i in 0..<block { fnv(&h, bufs[0]![i]); fnv(&h, bufs[1]![i]) }
        }
    }
    return h
}

/// ein Plugin-Slot (aus SNGL PLUGIN): an mit D/W 0,6, dann aus – bitgleich zur früheren Kette mit einem Plugin
@Test func fxPluginSlotBitIdenticalToOldChain() throws {
    let h = try fxGoldenPlugin { e, p, on in
        var kinds: [Int32] = [Int32(MDFX_KIND_PLUGIN.rawValue)]
        var list: [OpaquePointer?] = [p]
        kinds.withUnsafeMutableBufferPointer { k in list.withUnsafeMutableBufferPointer { mdsp_set_fx_rack(e, 0, 0, k.baseAddress, $0.baseAddress, 1) } }
        mdsp_set_fx_slot(e, 0, 0, on, 1)
    }
    #expect(h == fxGoldenHashes["plugin"], "\(String(h, radix: 16))")
}
