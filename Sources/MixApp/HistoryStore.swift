import Foundation
import Observation
import MixCore
import MixEngine

/// History und Preparation-Archiv – gespeichert als NML, direkt in die Collection importierbar.
@MainActor @Observable
final class HistoryStore {
    /// Datenordner neben der Collection (DataDir)
    nonisolated static var baseDir: URL { DataDir.shared }
    static let historyDir = baseDir.appendingPathComponent("History")
    static let prepDir = baseDir.appendingPathComponent("Preparation")
    static let externalHistoryDir = LibraryStore.defaultNML.deletingLastPathComponent().appendingPathComponent("History")

    /// laufende Session (beginnt mit dem App-Start)
    private(set) var live: [HistoryEntry] = []
    /// schon gespielte Tracks (Haken im Browser), bis „Reset Played State“
    private(set) var played: Set<String> = []
    /// zählt bei jeder Änderung der Gespielt-Markierungen hoch (Listen-Schlüssel beim Ausblenden)
    @ObservationIgnored private(set) var playedRevision = 0
    static let playedURL = baseDir.appendingPathComponent("played.json")
    /// Serielle Warteschlange für played.json und die Archiv-Verzeichnisse (läuft bei jedem Track-Start, nicht auf dem Hauptthread)
    nonisolated private static let ioQueue = DispatchQueue(label: "minos741.history-io", qos: .utility)
    /// eigene Änderung der Gespielt-Markierungen (hinzu, weg) – Zwei-Mac-Modus schickt sie zum anderen Mac
    @ObservationIgnored var onPlayedChange: ((_ add: Set<String>, _ remove: Set<String>) -> Void)?
    let sessionStart = Date()
    private(set) var archive: [HistorySession] = []
    private(set) var prepArchive: [HistorySession] = []
    @ObservationIgnored private var cache: [String: [HistoryEntry]] = [:]
    @ObservationIgnored private let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    @ObservationIgnored weak var store: LibraryStore?
    @ObservationIgnored weak var mix: MixModel?
    @ObservationIgnored private var timer: Timer?

    /// eigene Sitzungsdatei: history_JJJJ-MM-TT-NN.nml (NN = Sitzung des Tages); die Kopie in den History-Ordner
    /// der Collection behält deren Namensschema mit Uhrzeit
    private(set) var liveURL: URL = HistoryStore.historyDir
    private var externalName = ""

    init() {
        try? FileManager.default.createDirectory(at: Self.historyDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.prepDir, withIntermediateDirectories: true)
        if !Session.isSelfTest, let d = try? Data(contentsOf: Self.playedURL), let k = try? JSONDecoder().decode([String].self, from: d) {
            let loaded = Set(k)
            played = Self.playedAtStart(loaded, ui: AppPrefs.load().ui)   // ⌘, -> BROWSER
            if played != loaded { savePlayed() }
        }
        let day = HistorySession.dayString(sessionStart)
        let used = ((try? FileManager.default.contentsOfDirectory(atPath: Self.historyDir.path)) ?? []).filter { $0.hasPrefix("history_\(day)-") }.count
        liveURL = Self.historyDir.appendingPathComponent(HistorySession.sessionFileName(day: sessionStart, number: used + 1))
        externalName = HistoryNMLWriter.fileName(for: sessionStart)
        refreshArchive()
    }

    /// beim Beenden: Spieldauern nachführen und sofort schreiben
    func finish() {
        updateDurations()
        save(sync: true)
        savePlayed(sync: true)
    }

    func start(store: LibraryStore, mix: MixModel) {
        self.store = store
        self.mix = mix
        mix.recorder.history = self
        mix.core.onPlayed = { [weak self] d, t, start in
            DispatchQueue.main.async { self?.record(deck: d, track: t, start: start) }
        }
        // Spieldauer der laufenden Einträge alle 5 s nachführen
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDurations() }
        }
    }

    // MARK: History

    /// alle Gespielt-Markierungen zurücksetzen (⌥⌘P, Rechtsklick auf TRACK COLLECTION)
    func resetPlayed() { resetPlayed(keys: played) }

    /// Gespielt-Markierungen nur für diese Tracks zurücksetzen (Auswahl, Playlist, Ordner, Preparation); der Rest bleibt
    func resetPlayed(keys: Set<String>) {
        let old = played
        let rest = Self.playedAfterReset(old, keys: keys)
        StatusCenter.post(.ok, String(localized: "Gespielt-Markierungen zurückgesetzt"), key: "played")
        guard rest != old else { return }
        setPlayed(rest)
        UndoStack.shared.record("Reset Played State", before: old, after: rest) { [weak self] b, _, undo in
            // Rückgängig: die Markierungen kommen zurück, inzwischen gespielte bleiben markiert; Wiederholen: wieder nur `keys`
            guard let self else { return }
            self.setPlayed(undo ? b.union(self.played) : self.played.subtracting(keys))
        }
    }

    /// gespielt nach dem Zurücksetzen von `keys` (pur)
    nonisolated static func playedAfterReset(_ played: Set<String>, keys: Set<String>) -> Set<String> {
        played.subtracting(keys)
    }

    /// gespielt beim Start (pur): leer, wenn „Played-Status beim Start zurücksetzen“ an ist
    nonisolated static func playedAtStart(_ played: Set<String>, ui: UIPrefs) -> Set<String> {
        ui.resetPlayedOnStart ? [] : played
    }

    /// Gespielt-Markierungen setzen (Reset, Rückgängig, Selbsttest)
    func setPlayed(_ s: Set<String>) {
        let add = s.subtracting(played), remove = played.subtracting(s)
        applyPlayed(s)
        if !add.isEmpty || !remove.isEmpty { onPlayedChange?(add, remove) }
    }

    /// Stand vom anderen Mac (Zwei-Mac-Modus): ohne Rückmeldung dorthin
    func applyPlayed(_ s: Set<String>) {
        guard s != played else { return }
        played = s
        playedRevision += 1
        savePlayed()
    }

    /// played.json: Kopie auf dem Hauptthread, Kodieren und Schreiben in der seriellen Warteschlange (Reihenfolge bleibt)
    private func savePlayed(sync: Bool = false) {
        guard !Session.isSelfTest else { return }
        let list = played.sorted(), url = Self.playedURL
        let write: @Sendable () -> Void = {
            if let d = try? JSONEncoder().encode(list) { try? d.write(to: url, options: .atomic) }
        }
        if sync { Self.ioQueue.sync(execute: write) } else { Self.ioQueue.async(execute: write) }
    }

    func record(deck: Int, track t: Track, start: Date) {
        if played.insert(t.key).inserted { playedRevision += 1; savePlayed(); onPlayedChange?([t.key], []) }
        live.append(HistoryEntry(key: t.key, title: t.title, artist: t.artist, bpm: t.bpm, keyText: t.openKey,
                                 deck: deck, start: start, duration: mix?.core.playedSeconds(deck) ?? 0))
        save()
        refreshArchiveInBackground()
    }

    private func updateDurations() {
        guard let mix else { return }
        var changed = false
        for d in 0..<MixEngine.deckCount {
            guard let key = mix.deck(d).track?.key,
                  let i = live.lastIndex(where: { $0.deck == d && $0.key == key }) else { continue }
            let secs = mix.core.playedSeconds(d)
            if secs > live[i].duration + 0.5 { live[i].duration = secs; changed = true }
        }
        if changed { save() }
    }

    /// NML bauen und schreiben im Hintergrund (lief alle 5 s auf dem Hauptthread -> Ruckler); beim Beenden synchron
    private func save(sync: Bool = false) {
        guard !live.isEmpty else { return }
        let entries = live, index = store?.entryIndex ?? NMLEntryIndex(), uuid = uuid, url = liveURL
        let external = mix?.prefs.ui.historyToExternal == true && (mix.map { !$0.prefs.ui.pair.on || $0.prefs.ui.pair.writes } ?? true) ? Self.externalHistoryDir.appendingPathComponent(externalName) : nil
        if ProcessInfo.processInfo.environment["MIX741_SELFTEST"] == "1" { SelfTest.historyURL = url }
        let write = {
            let text = HistoryNMLWriter.nml(entries: entries, index: index, uuid: uuid)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            if let external { try? text.write(to: external, atomically: true, encoding: .utf8) }
        }
        if sync { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }

    func refreshArchive() {
        let r = Self.scanArchive(live: liveURL, historyDir: Self.historyDir, externalDir: Self.externalHistoryDir, prepDir: Self.prepDir)
        archive = r.archive
        prepArchive = r.prep
    }

    /// wie `refreshArchive`, die Verzeichnisse lesen im Hintergrund (bei jedem Track-Start). Ergebnisse in Reihenfolge
    private func refreshArchiveInBackground() {
        let live = liveURL, hist = Self.historyDir, ext = Self.externalHistoryDir, prep = Self.prepDir
        Self.ioQueue.async {
            let r = Self.scanArchive(live: live, historyDir: hist, externalDir: ext, prepDir: prep)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.archive = r.archive; self.prepArchive = r.prep }
            }
        }
    }

    /// Archiv und Preparation-Archiv aus den Ordnern (pur, auch im Hintergrund)
    nonisolated static func scanArchive(live: URL, historyDir: URL, externalDir: URL, prepDir: URL)
        -> (archive: [HistorySession], prep: [HistorySession]) {
        func list(_ dir: URL, _ src: HistorySession.Source) -> [HistorySession] {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "nml" }
                .compactMap { u in HistorySession.date(fromFileName: u.lastPathComponent).map { HistorySession(url: u, date: $0, source: src) } }
        }
        let own = list(historyDir, .live).filter { $0.url != live }
        let ownNames = Set(own.map(\.url.lastPathComponent))
        let external = list(externalDir, .external).filter { !ownNames.contains($0.url.lastPathComponent) }
        return ((own + external).sorted { $0.date > $1.date }, list(prepDir, .live).sorted { $0.date > $1.date })
    }

    func entries(_ s: HistorySession) -> [HistoryEntry] {
        if let c = cache[s.id] { return c }
        let e = HistoryNMLParser.parse(url: s.url)
        cache[s.id] = e
        return e
    }

    // MARK: Preparation-Archiv

    /// Beim Start: Preparation der letzten Session als NML archivieren und leeren (mit Verlauf).
    func archivePreparation(keys: [String], date: Date) {
        guard !keys.isEmpty, let store else { return }
        let name = "Preparation " + Theme.dateFormat.string(from: date)
        let entries = keys.map { k -> HistoryEntry in
            let t = store.byKey[k]
            return HistoryEntry(key: k, title: t?.title ?? "", artist: t?.artist ?? "", bpm: t?.bpm ?? 0,
                                keyText: t?.openKey ?? "", deck: 0, start: date, duration: 0)
        }
        let text = PlaylistNMLWriter.nml(name: name, entries: entries, index: store.entryIndex)
        let file = HistoryNMLWriter.fileName(for: date).replacingOccurrences(of: "history_", with: "preparation_")
        try? text.write(to: Self.prepDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        refreshArchive()
    }

    func prepKeys(_ s: HistorySession) -> [String] {
        (try? NMLParser.parse(url: s.url))?.root.children.first?.trackKeys ?? []
    }
}
