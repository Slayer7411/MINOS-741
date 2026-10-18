import AppKit
import Foundation
import MixEngine

/// Lücken des Hauptthreads: ein Timer mit 120 Hz, jede Lücke zwischen zwei Takten über 16 ms bzw. 50 ms zählt.
/// Dauerhaft an (ein Timer, zwei Zähler, kein Log). Abfrage: E2E-Befehl `ui-stats`. MIX741_DEBUG druckt jede Lücke > 50 ms.
@MainActor
enum MainStall {
    struct Stats: Equatable {
        var ticks = 0
        /// Lücken über 16 ms (ein verpasster Bildtakt) und über 50 ms (sichtbares Ruckeln)
        var over16 = 0, over50 = 0
        /// längste Lücke seit Start oder `reset` (ms)
        var maxMs = 0.0
    }

    private(set) static var stats = Stats()
    private static var timer: Timer?
    private static var last = CACurrentMediaTime()

    /// einmal beim Start; danach läuft der Zähler bis zum Ende
    static func start() {
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // auch bei offenem Menü und beim Ziehen eines Fensters
        timer = t
    }

    static func reset() { stats = Stats() }

    private static func tick() {
        let now = CACurrentMediaTime(), gap = (now - last) * 1000
        last = now
        stats.ticks += 1
        stats.maxMs = max(stats.maxMs, gap)
        if gap > 16 { stats.over16 += 1 }
        if gap > 50 {
            stats.over50 += 1
            if MixController.debug { print(String(format: "[hitch] main thread %.0f ms", gap)); fflush(stdout) }
        }
    }
}
