import Foundation
import CoreMIDI
import Testing
import MixCore
@testable import MixEngine

/// Groove-Ausgabe gegen eine feste Clock (120 BPM, Beat 0 = Start): Zeitstempel auf dem Raster, vor der Zeit gesendet,
/// über CoreMIDI an einem eigenen Eingang angekommen. Quelle versteckt (für andere Programme unsichtbar).
@Test func grooveOutTimestampsFollowTheClock() async throws {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var sent: [(stamp: UInt64, at: UInt64, beat: Double, on: Bool)] = []
        var received: [(stamp: UInt64, status: UInt8)] = []
        var halted = false
    }
    let box = Box()
    let out = GrooveOut(name: "MINOS-741 Groove Test", hidden: true)
    guard out.open() else {
        print("CoreMIDI nicht verfügbar: \(out.lastError ?? "?") – übersprungen")
        return
    }
    // eigener Eingang an der versteckten Quelle
    var client = MIDIClientRef(), port = MIDIPortRef()
    #expect(MIDIClientCreateWithBlock("groove test" as CFString, &client) { _ in } == noErr)
    #expect(MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { list, _ in
        // ein Paket kann mehrere Ereignisse gleicher Zeit tragen (je ein Wort)
        for p in list.unsafeSequence() {
            let n = Int(p.pointee.wordCount), stamp = p.pointee.timeStamp
            withUnsafeBytes(of: p.pointee.words) { raw in
                for w in raw.bindMemory(to: UInt32.self).prefix(n) {
                    box.lock.withLock { box.received.append((stamp, UInt8(w >> 16 & 0xFF))) }
                }
            }
        }
    } == noErr)
    #expect(MIDIPortConnectSource(port, out.endpoint, nil) == noErr)

    out.onSend = { s in
        let on = s.bytes.0 & 0xF0 == 0x90
        box.lock.withLock {
            box.sent.append((s.hostTime, mach_absolute_time(), s.beat, on))
            // nach dem dritten Note-On hält der Takt an: die Sendungen hängen nicht davon ab, wann der Test-Thread aufwacht
            if on, box.sent.filter(\.on).count == 3 { box.halted = true }
        }
    }
    var notes = [GrooveNote]()
    for s in stride(from: 2, to: 16, by: 4) { notes.append(GrooveNote(step: s, length: 1, channel: 9, note: 42, velocity: 100)) }
    let t0 = mach_absolute_time() + LinkSession.hostTicks(seconds: 0.05)
    out.start(clip: GrooveClip(steps: 16, notes: notes), origin: 0) {
        box.lock.withLock { box.halted } ? nil : GrooveOut.Clock(beat: 0, hostTime: t0, bpm: 120)
    }
    // bis drei Note-Ons gesendet sind (Beat 2,5 = 1,25 s); Frist per Uhr, nicht per Schleifenzahl (voller Rechner)
    let deadline = Date().addingTimeInterval(30)
    while box.lock.withLock({ !box.halted }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    out.stop()
    try await Task.sleep(for: .milliseconds(100))
    MIDIPortDispose(port); MIDIClientDispose(client)

    let sent = box.lock.withLock { box.sent }, received = box.lock.withLock { box.received }
    let ons = sent.filter(\.on)
    // 120 BPM: Offbeats 0,5 / 1,5 / 2,5 (0,25 / 0,75 / 1,25 s)
    #expect(ons.map(\.beat) == [0.5, 1.5, 2.5])
    var late = 0
    for e in ons {
        // Queue zu spät dran (voller Rechner): Zeitstempel = jetzt, nicht prüfbar
        if e.stamp <= e.at { late += 1; continue }
        let want = t0 + LinkSession.hostTicks(seconds: e.beat * 0.5)
        let second = Double(LinkSession.hostTicks(seconds: 1))
        let err = abs(Double(Int64(bitPattern: e.stamp &- want))) / second
        #expect(err < 1e-4, "Zeitstempel weicht ab: \(err) s")
        // vor der Zeit gesendet, höchstens Vorlauf + ein Takt der Queue
        let lead = Double(Int64(bitPattern: e.stamp &- e.at)) / second
        #expect(lead > 0 && lead <= GrooveOut.lookahead + GrooveOut.tick + 0.005, "Vorlauf \(lead) s")
    }
    // voller Rechner (CI-Runner mit 3 Kernen): einzelne Note-Ons kommen zu spät zur Queue – mindestens eines muss
    // vorausgeplant und damit geprüft worden sein
    #expect(late < ons.count, "\(late) von \(ons.count) Note-Ons zu spät geplant")
    // Note-Offs + All Notes Off beim Anhalten, alles über CoreMIDI angekommen
    #expect(sent.filter { $0.on }.count == 3 && sent.count == 7)
    #expect(received.count == sent.count, "gesendet \(sent.count), angekommen \(received.count)")
    #expect(received.filter { $0.status == 0x99 }.count == 3 && received.filter { $0.status == 0x89 }.count == 3)
    #expect(received.contains { $0.status == 0xB9 })
}
