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
    private var window: (Double, Double)?
    func block(_ seconds: Double) {
        lock.lock()
        let first = armed
        armed = false
        lock.unlock()
        guard first else { return }
        let start = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: seconds)
        lock.lock(); window = (start, ProcessInfo.processInfo.systemUptime); lock.unlock()
    }
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return window != nil }
    var span: (Double, Double)? { lock.lock(); defer { lock.unlock() }; return window }
}

/// Zeitpunkte der Tick-Handler (alle 6 Ticks, also alle ~30 ms)
private final class TickLog: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    func mark() { lock.lock(); times.append(ProcessInfo.processInfo.systemUptime); lock.unlock() }
    /// Zahl der Marken innerhalb des Zeitfensters
    func count(in span: (Double, Double)?) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let span else { return 0 }
        return times.filter { $0 >= span.0 && $0 <= span.1 }.count
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
    // Regler 2 auf die Filterfrequenz: die Stellung wird vom Plugin gelesen (blockiert 200 ms)
    core.setFXMapping(0, .knob2, freq.id)
    try await waitFor(3) { gate.didEnter }
    try await Task.sleep(for: .milliseconds(300))
    #expect(gate.didEnter)
    // Handler alle 6 Ticks (~30 ms): während der 200 ms Lesen mehrere Durchläufe (ohne die Naht: keiner)
    #expect(ticks.count(in: gate.span) >= 2)
}
