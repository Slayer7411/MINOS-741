import Foundation
import Testing
import MixCore
@testable import MixApp

// Suche in den Einstellungen: Index <-> Anker im Quelltext, englische Texte, Treffer und Rang

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let english = NSDictionary(contentsOf: root.appendingPathComponent("Localization/en.lproj/Localizable.strings")) as? [String: String] ?? [:]
private let search = SettingsSearch(entries: SettingsIndex.entries, english: english)

private func anchorCounts() throws -> (literal: [String: Int], dynamic: Int) {
    let dir = root.appendingPathComponent("Sources/MixApp")
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
    let literal = try NSRegularExpression(pattern: #"\.settingsAnchor\("([^"]+)"\)"#)
    var counts: [String: Int] = [:], dynamic = 0
    for f in files {
        let s = try String(contentsOf: f, encoding: .utf8)
        for m in literal.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            counts[String(s[Range(m.range(at: 1), in: s)!]), default: 0] += 1
        }
        dynamic += s.components(separatedBy: ".settingsAnchor(SettingsIndex.keyAnchor(").count - 1
    }
    return (counts, dynamic)
}

@Test func settingsIndexMatchesAnchorsInSource() throws {
    let (counts, dynamic) = try anchorCounts()
    let indexed = Set(SettingsIndex.rows.map(\.anchor))
    for a in indexed.sorted() { #expect(counts[a] == 1, "Anker \(a): \(counts[a] ?? 0)× im Quelltext") }
    for a in counts.keys.sorted() { #expect(indexed.contains(a), "Anker \(a) fehlt im SettingsIndex") }
    for e in SettingsIndex.rows { if let alt = e.alt { #expect(indexed.contains(alt), "alt \(alt) von \(e.anchor)") } }
    // Tastatur: eine Zeile je Aktion über den berechneten Anker
    #expect(dynamic == 1)
    let keys = SettingsIndex.shortcuts.map(\.anchor)
    #expect(keys.count == ShortcutID.allCases.count && Set(keys).count == keys.count)
    #expect(Set(SettingsIndex.entries.map(\.tab)) == Set(SettingsView.tabs.map(\.id)))
}

@Test func settingsIndexHasEnglishTexts() {
    #expect(english.count > 1000)
    var missing: [String] = []
    for e in SettingsIndex.rows {
        for k in [e.tab, e.section, e.label] + (e.hint.map { [$0] } ?? []) where english[k] == nil { missing.append(k) }
    }
    #expect(missing.isEmpty, "ohne Englisch: \(Set(missing).sorted())")
}

@Test func settingsSearchRanksNameBeforeHint() {
    let hits = search.search("puffer")
    #expect(hits.first?.entry.anchor == "audio.buffer")
    // Wortanfang vor Teilwort, Name vor Hinweis
    let parallel = hits.firstIndex { $0.entry.anchor == "audio.parallel" }   // nur im Hinweis („Puffern“)
    #expect(parallel != nil && parallel! > 0)
    #expect(search.search("loop").first.map { $0.entry.label.hasPrefix("Loop") } == true)
}

@Test func settingsSearchFoldsCaseAndAccents() {
    #expect(search.search("HOHEN-BETONUNG").contains { $0.entry.anchor == "display.wave.highboost" })
    #expect(search.search("verzogerung").first?.entry.anchor == "fx.reverbpredelay")
    #expect(search.search("grosse").contains { $0.entry.anchor == "decks.loopsize" })   // ß -> ss
    #expect(search.search("ÜBERSICHT").contains { $0.entry.anchor == "decks.overviewheight" })
}

@Test func settingsSearchNeedsAllWords() {
    let both = search.search("reverb pegel")
    #expect(both.first?.entry.anchor == "fx.reverblevel")
    #expect(both.allSatisfy { $0.entry.tab == "MIXER & FX" })
    #expect(search.search("reverb xyzzy").isEmpty)
    #expect(search.search("   ").isEmpty)
}

@Test func settingsSearchFindsEnglishAndSynonyms() {
    #expect(search.search("sample rate").first?.entry.anchor == "audio.samplerate")
    #expect(search.search("buffer").first?.entry.anchor == "audio.buffer")
    #expect(search.search("latency").first?.entry.anchor == "audio.buffer")
    #expect(search.search("latenz").first?.entry.anchor == "audio.buffer")
    #expect(search.search("waveform").contains { $0.entry.tab == "ANZEIGE" })
    #expect(search.search("bpm").contains { $0.entry.anchor == "decks.temporange" })   // bpm <-> tempo
    // Tastatur: Aktion über Titel und ID
    #expect(search.search("reloop").contains { $0.entry.anchor == SettingsIndex.keyAnchor(.reloop) })
    #expect(search.search("hotcue").contains { $0.entry.tab == "CONTROLLER & TASTEN" })
}

/// CPU-Zeit des aufrufenden Threads in Sekunden: unter Last zählt nur die eigene Rechenzeit, nicht das Warten auf einen Kern
private func threadCPUSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

@Test func settingsSearchIsFast() {
    _ = search.search("loo")
    // Minimum aus 5 Läufen: ein Lauf, den der Scheduler unterbricht, zählt nicht. Schwelle 2 ms je Suche bleibt.
    var best = Double.infinity
    for _ in 0..<5 {
        let t0 = threadCPUSeconds()
        for q in ["loo", "puf", "rev", "bpm", "cue"] { _ = search.search(q) }
        best = min(best, threadCPUSeconds() - t0)
    }
    #expect(best / 5 < 0.002)
}
