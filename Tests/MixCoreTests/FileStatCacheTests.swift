import Foundation
import Testing
@testable import MixCore

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    var value: Int { lock.withLock { v } }
    func inc() { lock.withLock { v += 1 } }
}

/// Auf dem Hauptthread liest die Ansicht nur den Zwischenspeicher: kein Dateizugriff, keine Wartezeit,
/// auch wenn die Prüfung eines Cloud-Pfads 300 ms dauert
@MainActor
@Test func mainThreadUsesCachedStatWithoutTouchingDisk() async throws {
    let stats = Flag(), finished = Flag()
    let cache = FileStatCache(maxAge: 60) { p in
        stats.inc()
        if p.hasSuffix("cloud.mp3") { Thread.sleep(forTimeInterval: 0.3) }
        return p.hasSuffix("local.mp3")
    }
    #expect(cache.cached("/m/local.mp3") == nil)   // noch nicht geprüft: nil, ohne Dateizugriff
    #expect(stats.value == 0)

    let t0 = CFAbsoluteTimeGetCurrent()
    cache.refresh(["/m/local.mp3", "/m/cloud.mp3"]) { finished.inc() }
    #expect(CFAbsoluteTimeGetCurrent() - t0 < 0.005)   // refresh kehrt sofort zurück
    #expect(cache.cached("/m/cloud.mp3") == nil)       // während der Prüfung: unbekannt, nicht warten

    for _ in 0..<300 where finished.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(finished.value == 1)
    #expect(stats.value == 2)

    let before = stats.value
    #expect(cache.cached("/m/local.mp3") == true)
    #expect(cache.cached("/m/cloud.mp3") == false)
    #expect(stats.value == before)                     // Zwischenspeicher lesen hat nicht geprüft
}

@Test func cachedEntryExpires() {
    let stats = Flag()
    let cache = FileStatCache(maxAge: 0) { _ in stats.inc(); return true }
    cache.refresh(["/m/a.mp3"])
    for _ in 0..<300 where stats.value == 0 { Thread.sleep(forTimeInterval: 0.01) }
    #expect(stats.value == 1)
    Thread.sleep(forTimeInterval: 0.01)
    #expect(cache.cached("/m/a.mp3") == nil)           // mit maxAge 0 veraltet sofort
}
