import Foundation
import CoreMIDI
import Testing
import MixCore
@testable import MixEngine

/// MIDI-Clock an ein virtuelles Ziel (eigener Client, gleicher Prozess): Start, Takte auf dem Raster mit Zeitstempel,
/// Stop. Gemessen wird der Empfang: Abstand der Zeitstempel gegen 120 BPM × 24 Takte, und der Verzug zwischen
/// Zeitstempel und Ankunft im Empfänger (CoreMIDI-Zustellung, nicht das Gerät).
@Test func midiClockArrivesOnTheGridAtVirtualDestination() async throws {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var sent: [(hostTime: UInt64, bytes: [UInt8])] = []
        var received: [(stamp: UInt64, at: UInt64, status: UInt8)] = []
    }
    let box = Box()
    let out = MIDIClockOut()
    guard out.open() else {
        print("CoreMIDI nicht verfügbar: \(out.lastError ?? "?") – übersprungen")
        return
    }
    var client = MIDIClientRef(), dest = MIDIEndpointRef()
    #expect(MIDIClientCreateWithBlock("clock test" as CFString, &client) { _ in } == noErr)
    #expect(MIDIDestinationCreateWithProtocol(client, "MINOS-741 Clock Test" as CFString, ._1_0, &dest) { list, _ in
        let at = mach_absolute_time()
        for p in list.unsafeSequence() {
            let n = Int(p.pointee.wordCount), stamp = p.pointee.timeStamp
            withUnsafeBytes(of: p.pointee.words) { raw in
                for w in raw.bindMemory(to: UInt32.self).prefix(n) {
                    box.lock.withLock { box.received.append((stamp, at, UInt8(w >> 16 & 0xFF))) }
                }
            }
        } } == noErr)

    out.onSend = { h, _, b in box.lock.withLock { box.sent.append((h, b)) } }
    out.setSongPosition(false)
    out.setTarget(dest)
    // Beat 0 liegt 50 ms in der Zukunft; Transport erst danach starten, damit keine Takte vor Beat 0 entstehen
    let t0 = mach_absolute_time() + LinkSession.hostTicks(seconds: 0.05)
    out.start { MIDIClockOut.Clock(beat: 0, hostTime: t0, bpm: 120) }
    try await Task.sleep(for: .milliseconds(80))
    out.setPlaying(true)
    // 1,5 s bei 120 BPM = 3 Beats = 72 Takte (plus Start, Stop)
    try await Task.sleep(for: .milliseconds(1500))
    out.setPlaying(false)
    try await Task.sleep(for: .milliseconds(150))
    out.stop()
    try await Task.sleep(for: .milliseconds(200))
    out.stop()
    MIDIEndpointDispose(dest)
    MIDIClientDispose(client)

    let sent = box.lock.withLock { box.sent }, received = box.lock.withLock { box.received }
    // Ankunft = Gesendetes, in der Reihenfolge
    #expect(received.count == sent.count, "gesendet \(sent.count), angekommen \(received.count)")
    #expect(received.first?.status == 0xFA, "erstes Ereignis: Start")
    #expect(received.last?.status == 0xFC, "letztes Ereignis: Stop")
    let clocks = received.filter { $0.status == 0xF8 }
    // Takte gegen das Raster, nicht gegen eine Anzahl in einem Wanduhr-Fenster (das streckt sich unter Last):
    // 1/48 s je Takt; lückenlos heißt Anzahl = Spanne der Zeitstempel / Takt + 1
    let perTick = Double(LinkSession.micros(hostTicks: LinkSession.hostTicks(seconds: 1))) / 1e6 / 48
    let span: Double = {
        guard let first = clocks.first, let last = clocks.last else { return 0 }
        return Double(LinkSession.micros(hostTicks: last.stamp &- first.stamp)) / 1e6
    }()
    #expect(clocks.count == Int((span / perTick).rounded()) + 1, "Takte \(clocks.count) passen nicht zum Raster über \(span) s")
    // Der Takt lief über das Spielfenster (1,5 s Wanduhr; Untergrenze 1,0 s, Rest als Puffer für Anlauf und Stopp)
    #expect(span >= 1.0, "Takte nur über \(span) s verteilt")
    // Zeitstempel auf dem Raster: 1/48 s Abstand (Fehler unter 0,5 ms, Host-Zeit-Rundung)
    var stampErr = 0.0
    for (a, b) in zip(clocks, clocks.dropFirst()) {
        let d = Double(LinkSession.micros(hostTicks: b.stamp &- a.stamp)) / 1e6
        stampErr = max(stampErr, abs(d - perTick))
    }
    #expect(stampErr < 0.0005, "Zeitstempel-Abstand weicht bis \(stampErr * 1000) ms ab")
    // Zustellung: Verzug Ankunft gegen Zeitstempel (informativ, grob begrenzt für überlastete Rechner)
    let late = clocks.map { Double(Int64(bitPattern: $0.at &- $0.stamp)) / Double(LinkSession.hostTicks(seconds: 1)) }.sorted()
    if let worst = late.last {
        let median = late[late.count / 2]
        let mean = late.reduce(0, +) / Double(late.count)
        let sd = (late.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(late.count)).squareRoot()
        print(String(format: "MIDI-Clock Zustellung: Takte %d, Median %.2f ms, Mittel %.2f ms, Streuung %.2f ms, schlechtester %.2f ms",
                     late.count, median * 1000, mean * 1000, sd * 1000, worst * 1000))
        #expect(worst < 0.1, "Takt kam \(worst * 1000) ms nach dem Zeitstempel an")
    }
    // gesendete Zeitstempel sind die empfangenen (keine Verschiebung im Weg)
    #expect(clocks.map(\.stamp) == sent.filter { $0.bytes == [0xF8] }.map(\.hostTime))
}
