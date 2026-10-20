import Foundation
@testable import MixEngine

/// Lade-Frist der Tests (Sekunden ohne Audiodaten, bis der Wächter abbricht). Ein Dekodieren dauert im Debug-Build
/// 0,6–2 s pro Datei, unter Last der ganzen Suite mehr: der Standard (4 s) würde gesunde Ladevorgänge abbrechen.
let testLoadTimeout: Double = 60

/// Einstellungen für Tests mit eigener Konfiguration: Standard, aber mit der Lade-Frist der Tests.
/// Nach `setPrefs` mit `EnginePrefs()` ohne diese Frist fällt der Wächter sonst auf 4 s zurück.
func testPrefs() -> EnginePrefs {
    var p = EnginePrefs()
    p.loadTimeout = testLoadTimeout
    return p
}

/// Steuerkern für Tests, die echte Dateien laden. Der Lade-Wächter (Standard 4 s ohne Audiodaten)
/// soll nur hängende Dekodierer abbrechen, nicht einen Lauf unter CPU-Last der ganzen Suite.
/// `prefs`: Einstellungen, mit denen der Kern einmal konfiguriert wird (sonst Standard).
func testController(_ prefs: EnginePrefs? = nil) -> MixController {
    let c = MixController()
    var p = prefs ?? EnginePrefs()
    p.loadTimeout = testLoadTimeout
    c.setPrefs(p)
    return c
}

/// Wartet, bis der Kern für jedes Deck in `decks` fertig geladen hat (Audio da) oder den Ladevorgang beendet
/// (Fehler, Abbruch). Feste Schleifen von 1–5 s reichten unter Last nicht: die Frist gilt hier der ganzen Suite.
func awaitLoaded(_ c: MixController, decks: [Int] = [0]) async throws {
    let t0 = Date()
    while decks.contains(where: { c.trackAudio($0) == nil && c.snapshot().decks[$0].loading }),
          Date().timeIntervalSince(t0) < testLoadTimeout {
        try await Task.sleep(for: .milliseconds(20))
    }
}
