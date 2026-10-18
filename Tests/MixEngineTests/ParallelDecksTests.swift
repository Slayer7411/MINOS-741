import Foundation
import Testing
import MixDSP

/// Decks parallel (Worker-Threads) gegen seriell: gleiche Eingaben, gleiche Blöcke -> identische Ausgabe.
/// Vier Decks mit verschiedenen Sinussen, Keylock auf B und D, EQ, Filter, Delay + Hall auf FX 1 (A/C) und FX 2 (B/D).
private final class FourDecks {
    let e: OpaquePointer
    let fs = 48000.0
    let frames: Int
    var bufs: [UnsafeMutablePointer<Float>] = []

    init(parallel: Bool, seconds: Double = 4) {
        e = mdsp_create(fs)
        frames = Int(seconds * fs)
        for d in 0..<4 {
            let f = [110.0, 220, 330, 440][d]
            let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0..<frames {
                let t = Double(i) / fs
                l[i] = Float(sin(2 * .pi * f * t)) * 0.4
                r[i] = Float(sin(2 * .pi * f * 1.5 * t)) * 0.3
            }
            bufs += [l, r]
            mdsp_set_track(e, Int32(d), l, r, Int64(frames), fs, 0)
            mdsp_set_param(e, Int32(d), MD_OUT_CHANNEL, Float(d * 2))
            mdsp_set_param(e, Int32(d), MD_KEYLOCK, d % 2 == 1 ? 1 : 0)
            mdsp_set_param(e, Int32(d), MD_RATE, [1.0, 1.04, 0.97, 1.1][d])
            mdsp_set_param(e, Int32(d), MD_EQ_LOW, Float(d) - 2)
            mdsp_set_param(e, Int32(d), MD_FILTER, Float(d) * 0.2 - 0.3)
            mdsp_set_param(e, Int32(d), MD_FX1_ASSIGN, d % 2 == 0 ? 1 : 0)
            mdsp_set_param(e, Int32(d), MD_FX2_ASSIGN, d % 2 == 1 ? 1 : 0)
            mdsp_set_param(e, Int32(d), MD_PLAYING, 1)
        }
        for u in 0..<2 {
            setRack(e, Int32(u), groupRack)
            mdsp_set_fx(e, Int32(u), MDFX_DELAY_ON, 1); mdsp_set_fx(e, Int32(u), MDFX_REVERB_ON, 1)
            mdsp_set_fx(e, Int32(u), MDFX_DRYWET, 0.5)
        }
        mdsp_set_parallel(e, parallel)
    }
    deinit { mdsp_destroy(e); for b in bufs { b.deallocate() } }

    /// `blocks` Blöcke zu `n` Frames auf 8 Kanälen rendern, alle Ausgaben hintereinander
    func render(blocks: Int, n: Int = 256) -> [Float] {
        var out = [Float](repeating: 0, count: 8 * n), all: [Float] = []
        all.reserveCapacity(8 * n * blocks)
        for _ in 0..<blocks {
            out.withUnsafeMutableBufferPointer { o in
                var chans: [UnsafeMutablePointer<Float>?] = (0..<8).map { o.baseAddress! + $0 * n }
                chans.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 8, Int32(n)) }
            }
            all += out
        }
        return all
    }
}

/// Die Frist der Worker ist Wanduhrzeit (2 Teilblöcke ab Blockanfang). Reißt unter Last eine Frist, fehlt dort das Deck
/// in diesem Block und der Kern rechnet danach seriell (Schutz vor Aussetzern, gewollt). Der Vergleich gilt also nur für
/// Läufe ohne Fristablauf; wer die Frist reißt, wird wiederholt (bis zu 5 Versuche). Bit-Gleichheit bleibt die Bedingung.
@Test func parallelDecksMatchSerial() {
    for attempt in 1...5 {
        let serial = FourDecks(parallel: false), parallel = FourDecks(parallel: true)
        #expect(!mdsp_parallel(serial.e) && mdsp_parallel(parallel.e))
        let a = serial.render(blocks: 60), b = parallel.render(blocks: 60)
        if watchdog(parallel.e).timeouts > 0 && attempt < 5 { continue }
        #expect(a.count == b.count)
        var peak: Float = 0
        for i in 0..<min(a.count, b.count) { peak = max(peak, abs(a[i] - b[i])) }
        #expect(peak == 0, "Abweichung parallel/seriell \(peak), Fristabläufe \(watchdog(parallel.e).timeouts)")
        #expect(a.contains { abs($0) > 0.05 }, "Ausgabe darf nicht still sein")
        #expect(abs(mdsp_position(serial.e, 1) - mdsp_position(parallel.e, 1)) < 1e-9)
        return
    }
}

@Test func parallelToggleWhileRendering() {
    let c = FourDecks(parallel: false)
    let before = c.render(blocks: 10)
    mdsp_set_parallel(c.e, true)
    let mid = c.render(blocks: 10)
    mdsp_set_parallel(c.e, false)
    let after = c.render(blocks: 10)
    for x in before + mid + after { #expect(x.isFinite) }
    #expect(mid.contains { abs($0) > 0.05 } && after.contains { abs($0) > 0.05 })
    // Position läuft durchgehend weiter: 30 Blöcke à 256 Frames, Deck A Tempo 1
    #expect(abs(mdsp_position(c.e, 0) - 30 * 256 / 48000.0) < 0.002)
}

@Test func parallelWithWorkgroupUnsetAndDestroy() {
    for _ in 0..<3 {
        let c = FourDecks(parallel: true, seconds: 1)
        mdsp_set_workgroup(c.e, nil, 256 / 48000.0)
        _ = c.render(blocks: 5)
    }   // mdsp_destroy beendet die Worker ohne zu hängen
}

@Test func renderProfileReportsWorstBlock() {
    let c = FourDecks(parallel: false, seconds: 1)
    _ = c.render(blocks: 20, n: 256)
    var parts = [UInt64](repeating: 0, count: 8), frames: UInt32 = 0
    mdsp_render_profile(c.e, &parts, 8, &frames)
    #expect(frames == 256)
    let total = parts.reduce(0, +)
    #expect(total > 0 && total < 50_000_000, "Gesamt \(total) ns")           // unter 50 ms
    #expect(parts[0] > 0 && parts[1] > 0 && parts[4] == 0, "seriell: Decks gemessen, kein Warten")
    mdsp_set_parallel(c.e, true)
    _ = c.render(blocks: 20, n: 256)
    mdsp_render_profile(c.e, &parts, 8, &frames)
    #expect(parts[0] > 0 && parts[1] == 0 && parts[4] > 0, "parallel: A hier, B–D im Warten")
    // Abholen setzt zurück: ohne neuen Block bleibt der letzte Wert stehen (Audio-Thread schreibt nur bei total > worst)
    mdsp_render_profile(c.e, &parts, 8, &frames)
    #expect(frames == 256)
}

/// RMS je Kanalpaar (A 1/2 … D 7/8) eines Blocks aus `render`
private func pairRMS(_ block: ArraySlice<Float>, n: Int) -> [Float] {
    (0..<4).map { p in
        var s: Float = 0
        for c in [2 * p, 2 * p + 1] { for i in 0..<n { let x = block[block.startIndex + c * n + i]; s += x * x } }
        return (s / Float(2 * n)).squareRoot()
    }
}

private func watchdog(_ e: OpaquePointer) -> MDParallelWatchdog {
    var w = MDParallelWatchdog()
    mdsp_parallel_watchdog(e, &w)
    return w
}

@Test func parallelWatchdogSkipsHungWorker() {
    let n = 256
    // Aufwärmen: 20 Blöcke parallel, bis ein Lauf ganz ohne Fristablauf bleibt. Unter CPU-Überlast reißt die Frist
    // (der Kern rechnet dann seriell); so ein Lauf zählt nicht und wird mit frischer, parallel geschalteter Instanz
    // wiederholt. Obergrenze 10 s.
    var c = FourDecks(parallel: true)
    let deadline = Date().addingTimeInterval(10)
    var warmed = false
    while !warmed && Date() < deadline {
        _ = c.render(blocks: 20, n: n)                    // eingeschwungen, Worker laufen
        if watchdog(c.e).timeouts == 0 && mdsp_parallel(c.e) {
            warmed = true
        } else {
            c = FourDecks(parallel: true)
        }
    }
    #expect(warmed, "kein Aufwärmen ohne Fristablauf innerhalb von 10 s")
    #expect(watchdog(c.e).timeouts == 0)
    mdsp_debug_stall_worker(c.e, 0, 300_000, false)        // Deck B hängt 300 ms beim Rechnen
    let t0 = Date()
    let hung = c.render(blocks: 1, n: n)
    let ms = Date().timeIntervalSince(t0) * 1000
    // Frist 2 × 5.3 ms ab Blockanfang, Obergrenze 250 ms (Last): ein wartender Block bräuchte ≥ 290 ms
    #expect(ms < 250, "Block dauerte \(ms) ms")
    let r = pairRMS(hung[...], n: n)
    #expect(r[1] == 0, "Deck B fehlt im Block")
    #expect(r[0] > 0.01 && r[2] > 0.01 && r[3] > 0.01, "A, C, D klingen: \(r)")
    #expect(!mdsp_parallel(c.e), "danach seriell")
    var w = watchdog(c.e)
    #expect(w.timeouts == 1 && w.stuck == 1)
    // seriell weiter: B bleibt still, solange sein Worker noch rechnet; A, C, D laufen
    let during = c.render(blocks: 5, n: n)
    for b in 0..<5 {
        let rb = pairRMS(during[(b * 8 * n)..<((b + 1) * 8 * n)], n: n)
        #expect(rb[1] == 0 && rb[0] > 0.01 && rb[2] > 0.01)
    }
    Thread.sleep(forTimeInterval: 0.35)                    // Worker wird fertig
    let after = c.render(blocks: 3, n: n)
    let ra = pairRMS(after[(2 * 8 * n)...], n: n)
    #expect(ra[1] > 0.01, "Deck B wieder da (seriell): \(ra)")
    w = watchdog(c.e)
    #expect(w.timeouts == 1 && w.stuck == 0)
    #expect(w.lastHangNs > 290_000_000, "Hängedauer \(w.lastHangNs) ns")
    #expect(!mdsp_parallel(c.e))
    // wieder einschalten: läuft parallel ohne weiteren Fristablauf
    mdsp_set_parallel(c.e, true)
    let again = c.render(blocks: 20, n: n)
    #expect(mdsp_parallel(c.e) && watchdog(c.e).timeouts == 1)
    #expect(pairRMS(again[(19 * 8 * n)...], n: n).allSatisfy { $0 > 0.01 })
}

@Test func parallelWatchdogCancelsLateWorker() {
    let c = FourDecks(parallel: true)
    let n = 256
    _ = c.render(blocks: 10, n: n)
    mdsp_debug_stall_worker(c.e, 2, 100_000, true)         // Deck D kommt 100 ms zu spät dran (vor der Übernahme)
    let t0 = Date()
    let late = c.render(blocks: 1, n: n)
    #expect(Date().timeIntervalSince(t0) * 1000 < 40)
    #expect(pairRMS(late[...], n: n)[3] == 0)
    let w = watchdog(c.e)
    #expect(w.timeouts == 1 && w.stuck == 0, "zurückgezogen, nicht hängend")
    // der Auftrag ist zurückgezogen: D rechnet sofort seriell weiter, der Worker rechnet ihn nicht mehr
    let next = c.render(blocks: 2, n: n)
    #expect(pairRMS(next[(8 * n)...], n: n)[3] > 0.01)
    let p = mdsp_position(c.e, 3)
    Thread.sleep(forTimeInterval: 0.15)                    // Worker wacht auf, findet den Auftrag zurückgezogen
    #expect(mdsp_position(c.e, 3) == p, "Worker darf das Deck nicht nachrechnen")
    mdsp_set_parallel(c.e, true)
    _ = c.render(blocks: 10, n: n)
    #expect(mdsp_parallel(c.e) && watchdog(c.e).timeouts == 1)
}
