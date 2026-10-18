import AppKit
import Foundation
import MixCore
import MixEngine

/// Lücken des Hauptthreads: ein Timer mit 120 Hz, jede Lücke zwischen zwei Takten über 16 ms bzw. 50 ms zählt.
/// Dauerhaft an (ein Timer, zwei Zähler). Lücken über 50 ms stehen im Statusprotokoll (Uhrzeit, Dauer).
/// Abfrage: E2E-Befehl `ui-stats`. Im E2E-Lauf hält ein Wächter Lücken über 100 ms mit `sample` im Lauf fest
/// (`<Lauf>/stalls/`, höchstens `stallSamples`).
@MainActor
enum MainStall {
    struct Stats: Equatable {
        var ticks = 0
        /// Lücken über 16 ms (ein verpasster Bildtakt) und über 50 ms (sichtbares Ruckeln)
        var over16 = 0, over50 = 0
        /// längste Lücke seit Start oder `reset` (ms)
        var maxMs = 0.0
    }

    /// Zeitpunkt des letzten Takts, vom Wächter gelesen (eigener Thread)
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = CACurrentMediaTime()
        func tick(_ now: Double) { lock.lock(); last = now; lock.unlock() }
        var value: Double { lock.lock(); defer { lock.unlock() }; return last }
    }

    private(set) static var stats = Stats()
    private static var timer: Timer?
    private static var last = CACurrentMediaTime()
    private static let clock = Clock()
    static let stallSamples = 8

    /// einmal beim Start; danach läuft der Zähler bis zum Ende
    static func start() {
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // auch bei offenem Menü und beim Ziehen eines Fensters
        timer = t
        if let root = E2E.root { startWatchdog(dir: root.appendingPathComponent("stalls", isDirectory: true)) }
    }

    static func reset() { stats = Stats() }

    /// Zählerstand vor dem Zurücksetzen (E2E `ui-stats` mit `reset`: je Abschnitt ein Stand)
    static func takeStats() -> Stats {
        let s = stats
        stats = Stats()
        return s
    }

    private static func tick() {
        let now = CACurrentMediaTime(), gap = (now - last) * 1000
        last = now
        clock.tick(now)
        stats.ticks += 1
        stats.maxMs = max(stats.maxMs, gap)
        if gap > 16 { stats.over16 += 1 }
        if gap > 50 {
            stats.over50 += 1
            // Statusprotokoll (lokal): jede Lücke über 50 ms mit Uhrzeit
            StatusLogFile.shared.append("\(StatusLogFile.stamp(Date())) info Hänger Hauptthread \(Int(gap.rounded())) ms")
            if MixController.debug { print("[hitch] main thread \(Int(gap.rounded())) ms"); fflush(stdout) }
        }
    }

    /// Wächter (nur E2E): steht der Hauptthread über 100 ms, nimmt `sample` den Stapel während des Stillstands auf
    private static func startWatchdog(dir: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let clock = clock, limit = stallSamples
        let thread = Thread {
            var taken = 0, sampling = false
            while true {
                Thread.sleep(forTimeInterval: 0.025)
                let now = CACurrentMediaTime()
                let stalled = now - clock.value
                if stalled < 0.1 { sampling = false; continue }
                guard !sampling, taken < limit else { continue }
                sampling = true
                taken += 1
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                p.arguments = ["\(pid)", "2", "-file", dir.appendingPathComponent("stall-\(taken).txt").path]
                try? p.run()
            }
        }
        thread.start()
    }
}
