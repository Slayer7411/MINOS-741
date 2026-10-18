import Foundation
@testable import MixEngine

/// Steuerkern für Tests, die echte Dateien laden. Der Lade-Wächter (Standard 4 s ohne Audiodaten)
/// soll nur hängende Dekodierer abbrechen, nicht einen Lauf unter CPU-Last der ganzen Suite.
/// `prefs`: Einstellungen, mit denen der Kern einmal konfiguriert wird (sonst Standard).
func testController(_ prefs: EnginePrefs? = nil) -> MixController {
    let c = MixController()
    var p = prefs ?? EnginePrefs()
    p.loadTimeout = 60
    c.setPrefs(p)
    return c
}
