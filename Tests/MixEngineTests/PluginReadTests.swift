import Foundation
import Testing
@testable import MixEngine

// Plugin-Stellungen lesen (AU out of process: IPC) und setzen geschieht außerhalb der Controller-Sperre:
// ein blockierter Lesevorgang darf den Steuertick (5 ms) nicht anhalten.

private func waitFor(_ seconds: Double = 15, _ cond: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !cond(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

/// Blockiert den ersten Lesevorgang für eine feste Zeit
private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private var entered = false
    func block(_ seconds: Double) {
        lock.lock()
        let first = armed
        armed = false
        if first { entered = true }
        lock.unlock()
        if first { Thread.sleep(forTimeInterval: seconds) }
    }
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
}

/// Zeitpunkte der Tick-Handler (alle 6 Ticks, also alle ~30 ms)
private final class TickLog: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    func mark() { lock.lock(); times.append(ProcessInfo.processInfo.systemUptime); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return times.count }
    var maxGap: Double {
        lock.lock(); defer { lock.unlock() }
        return zip(times.dropFirst(), times).map { $0 - $1 }.max() ?? 0
    }
}

@Test func blockedPluginReadDoesNotStallControlTick() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-pluginread-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let core = testController()
    core.pluginCatalog = PluginCatalog(directory: dir.appendingPathComponent("store"), folders: [], vst3Folders: [])
    core.setSlots(0, [FXSlot(id: "aufx:mrev:appl")])
    try await waitFor { core.snapshot().fxParams[0].contains { $0.pluginParam != nil } }
    let freq = try #require(core.snapshot().fxParams[0].first { $0.name == "Filter Frequency" })

    let ticks = TickLog()
    core.addTickHandler { _ in ticks.mark() }
    try await Task.sleep(for: .milliseconds(100))
    let gate = ReadGate()
    core.readPluginValue = { inst, pid in gate.block(0.2); return inst.value(pid) }
    let before = ticks.count
    // Regler 2 auf die Filterfrequenz: die Stellung wird vom Plugin gelesen (blockiert 200 ms)
    core.setFXMapping(0, .knob2, freq.id)
    try await waitFor(3) { gate.didEnter }
    try await Task.sleep(for: .milliseconds(300))
    #expect(gate.didEnter)
    #expect(ticks.count - before >= 6)          // Ticks laufen während des Lesens weiter
    #expect(ticks.maxGap < 0.1)                  // kein Stillstand von 200 ms
}
