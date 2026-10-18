import Foundation
import Testing
@testable import MixEngine

/// Gerät wechseln blockiert die Oberfläche nicht: `applyAsync` kehrt vom Hauptthread sofort zurück, auch wenn das
/// Öffnen 300 ms dauert. Ohne Audio-Hardware: das Öffnen ist ein Testersatz (`openSeamForTest`) auf der Geräte-Queue.

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.withLock { v } }
    func set() { lock.withLock { v = true } }
}

@MainActor
@Test func switchingDeviceFromMainReturnsBeforeSlowOpenFinishes() async throws {
    let eng = MixEngine(rate: 48000)
    let opened = Flag(), done = Flag()
    eng.openSeamForTest = { _ in
        Thread.sleep(forTimeInterval: 0.3)
        opened.set()
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    eng.applyAsync(MixEngine.Routing(device: 1, firstChannel: [0, 0, 0, 0]), restart: true) { done.set() }
    let callMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    #expect(callMs < 5, "applyAsync brauchte \(callMs) ms")
    #expect(eng.busy)                 // Oberfläche zeigt „Öffne …“
    #expect(!opened.value)

    for _ in 0..<300 where !done.value { try await Task.sleep(for: .milliseconds(10)) }
    #expect(opened.value)
    #expect(done.value)               // Abschluss kam auf dem Hauptthread
    #expect(!eng.busy)
    #expect(CFAbsoluteTimeGetCurrent() - t0 >= 0.3)
}
