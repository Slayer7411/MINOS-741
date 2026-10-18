import Foundation
import Testing
import MixCore
import MixEngine

/// Zwei Ladevorgänge auf dasselbe Deck kurz hintereinander: der zuletzt gewählte Track gewinnt,
/// auch wenn der erste (lange Datei, Ratenwandlung) später fertig dekodiert ist.
@Test func lastLoadWinsWhenDecodesFinishOutOfOrder() async throws {
    let c = testController()
    let rate = c.engine.sampleRate
    let slow = try writeWAV(rate: rate == 48000 ? 44100 : 48000, channels: 2, seconds: 150)
    let fast = try writeWAV(rate: rate, channels: 2, seconds: 1)
    defer { try? FileManager.default.removeItem(at: slow); try? FileManager.default.removeItem(at: fast) }
    c.load(Track(key: "slow", path: slow.path), deck: 0)
    try await Task.sleep(for: .milliseconds(5))
    c.load(Track(key: "fast", path: fast.path), deck: 0)
    // gleich lange dekodieren wie der Hintergrund-Ladevorgang des ersten Tracks -> der ist danach sicher fertig
    _ = try TrackAudio.decode(url: slow, sampleRate: rate)
    for _ in 0..<50 where c.snapshot().decks[0].loading { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(300))
    let s = c.snapshot().decks[0]
    #expect(s.track?.key == "fast")
    #expect(!s.loading)
    #expect(abs((c.trackAudio(0)?.duration ?? 0) - 1) < 0.05)
}
