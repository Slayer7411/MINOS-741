import AppKit
import SwiftUI
import Observation
import MixCore
import MixEngine

/// Hält die geladene Collection; alle Browser-Bereiche lesen daraus.
@MainActor @Observable
final class LibraryStore {
    /// Collection-Datei, die die Einrichtung gewählt hat (`ui.collectionPath`, beim Start aus den Einstellungen gelesen)
    nonisolated(unsafe) static var chosenNML: URL? = readChosenNML()

    nonisolated static func readChosenNML() -> URL? {
        guard let data = E2E.defaults.data(forKey: AppPrefs.key),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ui = obj["ui"] as? [String: Any], let p = ui["collectionPath"] as? String, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Standard-Collection: die gewählte (wenn sie noch da ist), sonst die automatisch gefundene (siehe `autoNML`)
    nonisolated static var defaultNML: URL {
        if let c = chosenNML, FileManager.default.fileExists(atPath: c.path) { return c }
        return E2E.collection ?? autoNML   // Ende-zu-Ende: eigene Collection der Instanz
    }

    /// automatisch: neueste `collection.nml` im Benutzerordner der Collection-Software
    nonisolated private static let autoNML: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Native Instruments")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        let found = dirs.filter { $0.lastPathComponent.hasPrefix("Traktor") }
            .map { $0.appendingPathComponent("collection.nml") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedDescending }
        return found.first ?? base.appendingPathComponent("Traktor 3.11.2/collection.nml")
    }()

    /// Collection-Software läuft? Dann nicht in die Collection-Datei schreiben – sie hält die Collection im Speicher
    /// und überschreibt die Datei beim Beenden.
    nonisolated static func collectionSoftwareRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            (app.localizedName ?? "").hasPrefix("Traktor")
                || (app.bundleIdentifier ?? "").localizedCaseInsensitiveContains("traktor")
                || (app.executableURL?.lastPathComponent ?? "").hasPrefix("Traktor")
        }
    }

    var tracks: [Track] = [] { didSet { revision += 1 } }
    /// zählt jede Änderung der Tracks (für Browser-Zwischenspeicher). Preparation und eigene Smartlists zählen getrennt
    /// (`sourceRevision`): sonst sortierte „An Preparation anhängen“ jeden Bereich neu, auch die Collection
    private(set) var revision = 0
    var root = PlaylistNode(name: "Playlists", kind: .folder)
    /// Tracks, die gerade auf den Decks liegen (A-D) – Quelle RUNNING TRACKS
    var running: [Track] = [] { didSet { runningRevision += 1 } }
    private(set) var runningRevision = 0
    var status = "Lade Collection …"
    var sourceURL: URL?
    /// nicht beobachtet: ändert sich nur zusammen mit `tracks` (Setzen eines beobachteten Wörterbuchs vergleicht alt
    /// mit neu – 14k Einträge, ~30 ms Hauptthread je Laden)
    @ObservationIgnored private(set) var byKey: [String: Track] = [:]
    /// Roh-Einträge der collection.nml (für NML-Exporte: History, Preparation)
    @ObservationIgnored private(set) var entryIndex = NMLEntryIndex()
    private var smartCache: [UUID: [Track]] = [:]
    @ObservationIgnored private var missingCache: (rev: Int, cloud: Int, list: [Track])?
    /// Playlist-Knoten nach ID (aktueller Baum)
    @ObservationIgnored private var nodes: [UUID: PlaylistNode] = [:]
    /// Treffer eigener Smartlists: Regeln + Stand (gespielt / Cloud, wenn die Regeln sie brauchen)
    @ObservationIgnored var ownCache: [UUID: OwnHit] = [:]
    struct OwnHit { var rules: SmartRules; var stamp: Int; var tracks: [Track] }

    /// eigener Playlist-Baum (Ordner, Playlists, Smartlists), gespeichert in `playlists.json` (OwnPlaylists.swift)
    var playlists: PlaylistTree = PlaylistFile.load() {
        didSet { playlistsChanged(from: oldValue) }
    }
    var playlistRevision = 0
    /// Änderungszähler je eigenem Eintrag (Browser-Zwischenspeicher)
    @ObservationIgnored var ownRevisions: [UUID: Int] = [:]
    /// Werte je Feld für die Vorschläge im Smartlist-Editor (Feld | Stand)
    @ObservationIgnored var suggestionCache: [String: [(value: String, count: Int)]] = [:]

    /// Preparation: wird gespeichert, beim nächsten Start archiviert und geleert (Selbsttest/Messung: nur im Speicher)
    var preparation: [String] = Session.isSelfTest ? [] : E2E.defaults.stringArray(forKey: "prep.current") ?? [] {
        didSet {
            preparationRevision += 1
            guard !Session.isSelfTest else { return }
            E2E.defaults.set(preparation, forKey: "prep.current")
            E2E.defaults.set(Date(), forKey: "prep.date")
            let ui = uiPrefs()
            if ui.writeCollection, ui.writePlaylists { scheduleWriteBack(after: 10) }
        }
    }
    private(set) var preparationRevision = 0
    /// Preparation ändern mit Rückgängig (Anhängen, Entfernen)
    func editPreparation(_ label: String, _ f: (inout [String]) -> Void) {
        let old = preparation
        var new = old
        f(&new)
        guard new != old else { return }
        preparation = new
        UndoStack.shared.record(label, before: old, after: new) { [weak self] b, a, undo in self?.preparation = undo ? b : a }
    }
    func appendToPreparation(_ keys: some Sequence<String>) {
        editPreparation(String(localized: "An Preparation anhängen")) { p in
            for k in keys where !p.contains(k) { p.append(k) }
        }
    }
    @ObservationIgnored var preparationArchived = false
    var preparationDate: Date { E2E.defaults.object(forKey: "prep.date") as? Date ?? Date() }
    /// einmal nach dem ersten Laden der Collection
    @ObservationIgnored var onLoaded: (() -> Void)?
    /// MUSIC FOLDERS (Dateibaum der Musik-Ordner)
    let folders = MusicFolderStore()

    /// Track zu einem Schlüssel: Collection, geschnittene Datei (CUTS) oder schon angezeigte Datei aus MUSIC FOLDERS
    func track(_ key: String) -> Track? { byKey[key] ?? cutStore.byKey[key] ?? folders.loose[key] ?? dawByKey[key] }

    /// Clips der DAW-Brücke als Tracks (Quelle DAW), gesetzt von DAWBridgeModel
    private(set) var dawRevision = 0
    @ObservationIgnored private(set) var dawTracks: [Track] = []
    @ObservationIgnored private var dawByKey: [String: Track] = [:]
    func setDAWTracks(_ t: [Track]) {
        dawTracks = t
        dawByKey = Dictionary(t.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        dawRevision += 1
    }

    /// geschnittene Dateien (Schneiden in der Wellenform): eigene Liste mit Metadaten, nie in der Collection-Datei
    @ObservationIgnored let cutStore = CutStore(url: Session.isSelfTest ? nil : HistoryStore.baseDir.appendingPathComponent("cuts.json"))
    private(set) var cutsRevision = 0
    @ObservationIgnored private var cutsChecked = false
    var cuts: [Track] { _ = cutsRevision; return cutStore.tracks }
    /// Tool-Loops: geschnittene Dateien mit dem Tag `tool-loop`
    var toolLoops: [Track] {
        let seps = browser?.separators() ?? " "
        return cuts.filter { ToolLoop.isToolLoop($0, separators: seps) }
    }

    /// neue geschnittene Datei: in CUTS und (liegt der Ordner in MUSIC FOLDERS) im Ordner mit ihren Metadaten
    func addCut(_ t: Track, source: Track) {
        cutStore.add(CutEntry(track: t, source: source.key, sourcePath: source.path))
        cutsRevision += 1
        folders.fileAdded(t.path)
        let ui = uiPrefs()
        if ui.writeCollection, ui.writeCuts { scheduleWriteBack() }
    }

    /// einmal nach dem Laden der Collection: fehlen Dateien in CUTS (im Hintergrund, Datei-Dienst wie die Collection)
    private func checkCuts() {
        guard !cutsChecked else { return }
        cutsChecked = true
        let list = cutStore.paths
        guard !list.isEmpty else { return }
        Task.detached(priority: .utility) {
            let paths = list.map(\.path)
            var gone = Set<String>()
            if let fs = FileServiceSetup.shared, !fs.unavailable {
                let states = fs.check(paths: paths)
                for (i, e) in list.enumerated() where states[i] == .missing || states[i] == .error { gone.insert(e.key) }
            } else {
                for e in list where !FileManager.default.fileExists(atPath: e.path) { gone.insert(e.key) }
            }
            let missing = gone
            await MainActor.run {
                self.cutStore.setMissing(missing)
                self.cutsRevision += 1
            }
        }
    }

    /// Tracks ohne Datei (Quelle MISSING): Cloud-Scan „fehlt“, sonst die Ladeprüfung (fileExists). Zwischenspeicher je Stand
    var missingTracks: [Track] {
        let cloud = CloudLibrary.shared
        if let c = missingCache, c.rev == revision, c.cloud == cloud.revision { return c.list }
        let list = tracks.filter { t in cloud.peek(t.path).map { $0 == .missing } ?? !t.fileExists }
        missingCache = (revision, cloud.revision, list)
        return list
    }

    /// Änderungszähler einer Quelle zusätzlich zu `revision` (Browser-Zwischenspeicher)
    func sourceRevision(_ s: BrowserSource, subfolders: Bool = false) -> Int {
        switch s {
        case .missing: CloudLibrary.shared.revision
        case .running: runningRevision
        case .preparation: preparationRevision
        case let .own(r): ownRevision(r)
        case .cuts, .toolLoops: cutsRevision
        case .cuts: cutsRevision
        case .ripTodo: RipChecks.shared.revision
        case .daw: dawRevision
        case let .folder(p): folders.stamp(p, recursive: subfolders)
        default: 0
        }
    }

    /// eigene Metadaten-Änderungen (Browser: Inline, Bearbeiten-Fenster), liegen über der Collection
    @ObservationIgnored let meta = MetadataStore(url: Session.isSelfTest ? nil : HistoryStore.baseDir.appendingPathComponent("metadata.json"))
    /// eigene Analysen (Tempo, Grid, Tonart, Lautheit) – liegen über Collection und Metadaten-Änderungen
    @ObservationIgnored var analysis: AnalysisStore { Analyses.shared.store }
    /// Collection-Stand bearbeiteter / analysierter Tracks (vor den eigenen Werten) – für „verwerfen“
    @ObservationIgnored private var collectionBase: [String: Track] = [:]
    @ObservationIgnored private var position: [String: Int] = [:]
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var writing = false
    /// eigene Hotcues / Grid / Schnitt (MixModel.edits): Schreiben in die Collection-Datei, Konfliktprüfung beim Laden
    @ObservationIgnored var edits: TrackEditStore?
    /// Einstellungen (Schreiben in die Collection-Datei, Playlists, Cuts)
    @ObservationIgnored var uiPrefs: () -> UIPrefs = { AppPrefs.load().ui }
    /// Einstellungen ändern (z. B. Schreiben in die Collection für eine Aktion einschalten)
    @ObservationIgnored var updateUIPrefs: (_ change: (inout UIPrefs) -> Void) -> Void = { _ in }
    /// eigene History-Sitzungen (Playlists in der Collection-Datei)
    @ObservationIgnored weak var history: HistoryStore?
    /// Tracks nach dem Schreiben neu aus der Datei (Decks: Vergleichsstand für eigene Hotcues)
    @ObservationIgnored var onRefreshed: (([Track]) -> Void)?
    /// Größe + Änderungszeit der Collection-Datei beim letzten Lesen / eigenen Schreiben
    @ObservationIgnored private var loadedStamp: FileStamp?
    /// nach dem nächsten Laden schreiben (Datei war extern geändert)
    @ObservationIgnored private var writeAfterLoad = false
    /// eigene Playlists, wie sie zuletzt in der Datei standen
    @ObservationIgnored private var writtenPlaylists: [NMLOwnNode]?
    /// umbenannte Dateien (alter Schlüssel -> neuer Ort), bis sie in der Collection-Datei stehen
    @ObservationIgnored private var pendingMoves: [String: NMLLocation] = LibraryStore.loadMoves()
    static var movesURL: URL { HistoryStore.baseDir.appendingPathComponent("collection-moves.json") }

    /// Laden/Neu-Laden: alles Teure im Hintergrund (Parsen, Datei-Check, eigene Änderungen, Indizes, Sortierung
    /// der sichtbaren Listen), auf dem Hauptthread nur noch eine Übergabe. Vorher hingen ↻ und ⌘O im Set
    /// 1–2 s (zwei Bereiche à ~540 ms lokalisiertes Sortieren von 14k Tracks plus Indizes und Freigabe der alten Liste).
    func load(_ url: URL = LibraryStore.defaultNML) {
        status = "Lade \(url.lastPathComponent) …"
        StatusCenter.post(.info, String(localized: "Collection wird geladen: \(url.lastPathComponent)"), detail: url.path, key: "collection")
        let meta = meta, analysis = analysis, edits = edits, moves = pendingMoves
        let conflictDir: URL? = Session.isSelfTest ? nil : HistoryStore.baseDir
        let first = tracks.isEmpty
        loadGeneration += 1
        let generation = loadGeneration
        // erster Start mit Vorrang, Neu-Laden im Set nachrangig (Decks laden und dekodieren zuerst)
        Task.detached(priority: first ? .userInitiated : .utility) {
            do {
                let start = CACurrentMediaTime()
                let fileStamp = FileStamp(url: url)
                var c = try NMLParser.parse(url: url)
                // umbenannte Dateien, die noch nicht in der Datei stehen: neuer Schlüssel + Pfad
                if !moves.isEmpty {
                    for i in c.tracks.indices {
                        guard let l = moves[c.tracks[i].key] else { continue }
                        c.tracks[i].key = l.key
                        c.tracks[i].path = NMLParser.plainDir(l.dir) + l.file
                    }
                }
                // Konflikt: Eintrag in der Datei seit der eigenen Änderung geändert -> Datei gewinnt, eigener Stand gesichert
                let conflicts = Self.takeConflicts(c.tracks, meta: meta, edits: edits, backupDir: conflictDir)
                // Datei-Existenz einmal parallel prüfen (statt pro Tabellenzeile). Mit Datei-Dienst im Helfer (hängt der
                // Cloud-Anbieter, wird der Helfer abgeschossen, unbekannte Pfade gelten als vorhanden)
                let paths = c.tracks.map(\.path)
                var missing = [Bool](repeating: false, count: paths.count)
                if let fs = FileServiceSetup.shared, !fs.unavailable {
                    let t0 = CACurrentMediaTime()
                    let states = fs.check(paths: paths)
                    for i in paths.indices { missing[i] = states[i] == .missing || states[i] == .error }   // wie fileExists: Fehler = fehlt
                    let unknown = states.lazy.filter { $0 == nil }.count
                    print(String(format: "[files] %d pfade geprüft (helfer): %.0f ms · fehlen %d · unbekannt %d", paths.count,
                                 (CACurrentMediaTime() - t0) * 1000, missing.lazy.filter { $0 }.count, unknown))
                } else {
                    missing.withUnsafeMutableBufferPointer { buf in
                        let b = buf
                        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                            b[i] = !FileManager.default.fileExists(atPath: paths[i])
                        }
                    }
                }
                for i in c.tracks.indices { c.tracks[i].fileMissing = missing[i] }
                // eigene Metadaten-Änderungen über die Collection legen
                var collectionBase: [String: Track] = [:]
                for i in c.tracks.indices {
                    guard let e = meta.edit(for: c.tracks[i].key) else { continue }
                    collectionBase[c.tracks[i].key] = c.tracks[i]
                    c.tracks[i] = e.apply(to: c.tracks[i])
                }
                // eigene Analysen darüber
                if analysis.count > 0 {
                    for i in c.tracks.indices {
                        guard let a = analysis.entry(for: c.tracks[i].key) else { continue }
                        if collectionBase[c.tracks[i].key] == nil { collectionBase[c.tracks[i].key] = c.tracks[i] }
                        c.tracks[i] = a.apply(to: c.tracks[i])
                    }
                }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let index = NMLEntryIndex(nmlText: text)
                // MUSIC FOLDERS: Pfad-Index und Standard-Ordner einmal je Collection
                let folderIndex = MusicFolder.pathIndex(c.tracks)
                let folderRoot = MusicFolder.defaultRoot(paths: c.tracks.filter(\.fileExists).map(\.path))
                let parsedByKey = Dictionary(c.tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                let base = collectionBase
                let parsedRoot = c.root
                let parsed = CACurrentMediaTime()
                // erster Start: Playlists und Sitzung (Quellen, Sortierung der Bereiche) vorab, damit gleich die
                // richtigen Listen vorsortiert werden; Neu-Laden: nur nachsehen, was die Bereiche gerade zeigen
                let own = await MainActor.run { OwnSnapshot(tree: self.playlists, context: self.smartContext(background: true)) }
                let (targets, old, oldByKey, previous, oldRoot): ([PresortKey], [Track], [String: Track], [PresortKey: [Track]], PlaylistNode) = await MainActor.run {
                    if first {
                        self.root = parsedRoot
                        self.byKey = parsedByKey
                        self.entryIndex = index
                        self.onLoaded?()
                        return (self.presortTargets(), [], [:], [:], parsedRoot)
                    }
                    return (self.presortTargets(), self.tracks, self.byKey, self.presorted, self.root)
                }
                var tracks = c.tracks, byKey = parsedByKey, root = parsedRoot
                // Neu-Laden: unveränderte Tracks als dieselben Werte übernehmen (gleicher Speicher). SwiftUI vergleicht
                // die alte mit der neuen Liste – mit geteilten Texten ist das ein Zeigervergleich statt 14k Textvergleichen
                if !oldByKey.isEmpty {
                    var same = 0
                    for i in tracks.indices {
                        if let o = oldByKey[tracks[i].key], o == tracks[i] { tracks[i] = o; same += 1 }
                    }
                    if same == tracks.count, tracks == old { tracks = old }
                    byKey = Dictionary(tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                }
                // Playlist-Baum: gleiche Knoten behalten ihre ID, unveränderter Baum bleibt derselbe (Baum-Liste ohne Neuaufbau)
                if !first {
                    root.adoptIDs(from: oldRoot)
                    if root.sameTree(oldRoot) { root = oldRoot }
                }
                var nodes: [UUID: PlaylistNode] = [:]
                root.index(into: &nodes)
                let position = Dictionary(tracks.indices.map { (tracks[$0].key, $0) }, uniquingKeysWith: { a, _ in a })
                let pre = Self.presort(targets, tracks: tracks, byKey: byKey, nodes: nodes, previous: previous, own: own)
                let sorted = CACurrentMediaTime()
                let newTracks = tracks, newByKey = byKey, newRoot = root, newNodes = nodes
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }   // inzwischen neuer Ladevorgang
                    let t0 = CACurrentMediaTime()
                    // alte Liste und Indizes nicht hier freigeben (14k Tracks freigeben kostet den Hauptthread ~50 ms)
                    Self.releaseLater((self.tracks, self.byKey, self.position, self.collectionBase, self.entryIndex,
                                       self.smartCache, self.ownCache, self.presorted))
                    self.tracks = newTracks
                    self.byKey = newByKey
                    self.position = position
                    self.collectionBase = base
                    self.entryIndex = index
                    self.smartCache = pre.smart
                    self.ownCache = [:]
                    for (id, hit) in pre.own where self.playlists.item(id)?.rules == hit.rules { self.ownCache[id] = hit }
                    self.presorted = pre.lists
                    self.presortRevision = self.revision
                    self.folders.collectionLoaded(index: folderIndex, defaultRoot: folderRoot)
                    self.onLoaded?()   // einmal je Start (prüft selbst)
                    self.checkCuts()
                    if first, !Session.isSelfTest, AppPrefs.load().ui.checkOnStart { ConsistencyWindow.show(store: self) }
                    if self.root !== newRoot { self.root = newRoot }
                    self.nodes = newNodes
                    self.sourceURL = url
                    self.loadedStamp = fileStamp
                    self.writtenPlaylists = nil
                    self.status = "\(newTracks.count) Tracks · \(url.lastPathComponent) · \(String(format: "%.1f", parsed - start)) s"
                    StatusCenter.post(.ok, String(localized: "Collection geladen: \(newTracks.count) Tracks"), detail: url.path, key: "collection")
                    if conflicts > 0 {
                        self.status = String(localized: "Konflikt: \(conflicts) Tracks in der Collection-Datei geändert – die Datei gilt, MINOS-Stand in metadata-konflikt.json / edits-konflikt.json")
                        StatusCenter.post(.warning, self.status, detail: HistoryStore.baseDir.path, key: "conflict")
                    }
                    if self.writeAfterLoad {
                        self.writeAfterLoad = false
                        self.scheduleWriteBack()
                    }
                    if Self.debug {
                        print(String(format: "[load] %d tracks · parsen+indizes %.0f ms · vorsortieren %d listen %.0f ms (hintergrund) · übergabe %.1f ms (hauptthread)",
                                     newTracks.count, (parsed - start) * 1000, pre.lists.count, (sorted - parsed) * 1000, (CACurrentMediaTime() - t0) * 1000))
                        fflush(stdout)
                    }
                }
            } catch {
                await MainActor.run {
                    self.status = "Fehler beim Laden: \(error)"
                    StatusCenter.post(.error, String(localized: "Collection nicht geladen: \(error.localizedDescription)"), detail: url.path, key: "collection")
                }
            }
        }
    }

    nonisolated static let debug = ProcessInfo.processInfo.environment["MIX741_DEBUG"] == "1" || ProcessInfo.processInfo.environment["MIX741_BENCH"] != nil
    @ObservationIgnored private var loadGeneration = 0

    /// Quelle + Sortierung einer vorsortierten Liste
    struct PresortKey: Hashable, @unchecked Sendable {
        var source: BrowserSource
        var order: [KeyPathComparator<Track>]
    }
    /// Browser-Zustand (für die Ziele des Vorsortierens)
    @ObservationIgnored weak var browser: BrowserState?
    /// im Hintergrund sortierte Listen der Bereiche; gültig nur für `presortRevision`
    @ObservationIgnored private var presorted: [PresortKey: [Track]] = [:]
    @ObservationIgnored private var presortRevision = -1

    /// vorsortierte Liste für einen Bereich (nil = selbst sortieren)
    func presorted(_ source: BrowserSource, order: [KeyPathComparator<Track>]) -> [Track]? {
        guard presortRevision == revision else { return nil }
        return presorted[PresortKey(source: source, order: order)]
    }

    private func presortTargets() -> [PresortKey] {
        guard let b = browser else { return [PresortKey(source: .collection, order: [KeyPathComparator(\Track.artist)])] }
        return Array(Set([b.paneA, b.paneB].map { PresortKey(source: $0.source, order: $0.sortOrder) }))
    }

    /// Basisliste einer Quelle ohne Hauptthread (nur Quellen, die allein aus der Collection kommen)
    nonisolated private static func baseTracks(_ s: BrowserSource, tracks: [Track], byKey: [String: Track],
                                               nodes: [UUID: PlaylistNode], own: OwnSnapshot) -> [Track]? {
        let none = SmartQuery.compare(field: "TITLE", op: .eq, value: .text("\u{0}"))
        switch s {
        case .collection: return tracks
        case let .own(r):
            guard let it = own.tree.item(r.id) else { return nil }
            switch it.kind {
            case .folder: return nil
            case .playlist: return it.tracks.compactMap { byKey[$0] }
            case .smartlist:
                // Cloud-Status und History gibt es nur auf dem Hauptthread
                guard !it.rules.usesAvailability, !it.rules.usesPlayed else { return nil }
                return it.rules.compile(own.context).apply(tracks)
            }
        case let .node(old):
            let n = nodes[old.id] ?? old
            switch n.kind {
            case .folder: return nil
            case .playlist: return n.trackKeys.compactMap { byKey[$0] }
            case .smartlist:
                let q = (try? SmartQuery.parse(n.query)) ?? none
                return tracks.filter { q.matches($0, now: own.context.now, played: own.context.played) }
            }
        default: return nil
        }
    }

    private struct Presorted: @unchecked Sendable {
        var lists: [PresortKey: [Track]] = [:]
        var smart: [UUID: [Track]] = [:]
        var own: [UUID: OwnHit] = [:]
    }

    /// Listen der Bereiche parallel sortieren (gleiches `TrackSort` wie im Bereich, nur nicht auf dem Hauptthread)
    /// Gleiche Liste wie beim letzten Laden -> derselbe Speicher: die Tabelle sieht keine Änderung und baut nichts neu.
    nonisolated private static func presort(_ targets: [PresortKey], tracks: [Track], byKey: [String: Track],
                                            nodes: [UUID: PlaylistNode], previous: [PresortKey: [Track]], own: OwnSnapshot) -> Presorted {
        var out = Presorted()
        var results = [[Track]?](repeating: nil, count: targets.count)
        var bases = [[Track]?](repeating: nil, count: targets.count)
        results.withUnsafeMutableBufferPointer { r in
            bases.withUnsafeMutableBufferPointer { b in
                let r = r, b = b
                DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                    guard let base = baseTracks(targets[i].source, tracks: tracks, byKey: byKey, nodes: nodes, own: own) else { return }
                    b[i] = base
                    let list = TrackSort.sorted(base, using: targets[i].order)
                    if let prev = previous[targets[i]], prev == list { r[i] = prev } else { r[i] = list }
                }
            }
        }
        for (i, t) in targets.enumerated() {
            guard let list = results[i], let base = bases[i] else { continue }
            out.lists[t] = list
            switch t.source {
            case let .own(r):
                if let it = own.tree.item(r.id), it.kind == .smartlist { out.own[r.id] = OwnHit(rules: it.rules, stamp: 0, tracks: base) }
            case let .node(n) where n.kind == .smartlist: out.smart[n.id] = base
            default: break
            }
        }
        return out
    }

    /// letzte Referenz im Hintergrund abgeben: das Freigeben großer Listen kostet sonst den Hauptthread
    nonisolated private static func releaseLater(_ old: Any) {
        let box = OldBox(old)
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1) { box.drop() }
    }
    private final class OldBox: @unchecked Sendable {
        private var value: Any?
        init(_ v: Any) { value = v }
        func drop() { value = nil }
    }

    // MARK: - Metadaten bearbeiten

    /// Änderungen übernehmen (Track-Schlüssel -> Feld -> kanonischer Wert): sofort in Liste, Suche, Sortierung;
    /// gespeichert in metadata.json; mit `writeBack` danach (gesammelt, einmal je Stapel) in die Collection-Datei.
    /// Rückgängig schreibt die Vorher-Werte über denselben Weg zurück (`exact`: Werte ungeprüft, wie sie waren)
    func applyEdits(_ changes: [String: [TrackField: String]], writeBack: Bool, exact: Bool = false) {
        var list = tracks
        var applied: [String: [TrackField: String]] = [:], previous: [String: [TrackField: String]] = [:]
        for (key, fields) in changes {
            guard let i = position[key], i < list.count, list[i].key == key else { continue }
            var t = list[i]
            let valid = fields.filter { f, v in f.isEditable(t) && (exact || f.normalize(v) == v) && f.value(of: t) != v }
            guard !valid.isEmpty else { continue }
            if collectionBase[key] == nil { collectionBase[key] = t }
            previous[key] = Dictionary(uniqueKeysWithValues: valid.keys.map { ($0, $0.value(of: t)) })
            for (f, v) in valid { f.set(v, on: &t) }
            t.buildSearchText()
            list[i] = t
            byKey[key] = t
            applied[key] = valid
        }
        guard !applied.isEmpty else { return }
        UndoStack.shared.record(String(localized: "Metadaten: \(applied.count) Tracks"), before: previous, after: applied) { [weak self] b, a, undo in
            self?.applyEdits(undo ? b : a, writeBack: writeBack, exact: true)
        }
        meta.merge(applied, base: collectionBase, stamps: applied.keys.reduce(into: [:]) { $0[$1] = collectionBase[$1]?.entryStamp })
        replaceRunning(applied.keys)
        smartCache = [:]
        ownCache = [:]
        tracks = list
        StatusCenter.post(.ok, String(localized: "Gespeichert: \(applied.count) Tracks (Metadaten)"), key: "edits")
        if writeBack { scheduleWriteBack() }
    }

    /// eigene Änderungen verwerfen -> wieder die Werte der Collection
    func revertEdits(_ keys: [String]) {
        var list = tracks
        var reverted: [String] = []
        for key in keys {
            guard let b = collectionBase[key], let i = position[key], i < list.count, list[i].key == key else { continue }
            var t = b
            t.fileMissing = list[i].fileMissing
            if let a = analysis.entry(for: key) { t = a.apply(to: t) } else { collectionBase[key] = nil }
            list[i] = t
            byKey[key] = t
            reverted.append(key)
        }
        meta.remove(keys)
        guard !reverted.isEmpty else { return }
        replaceRunning(reverted)
        smartCache = [:]
        ownCache = [:]
        tracks = list
    }

    func hasEdits(_ keys: some Sequence<String>) -> Bool { keys.contains { meta.edit(for: $0) != nil } }
    func hasAnalysis(_ keys: some Sequence<String>) -> Bool { keys.contains { analysis.entry(for: $0) != nil } }

    // MARK: - Eigene Analyse

    /// neue Analysen über die Tracks legen (Collection, lose Dateien aus MUSIC FOLDERS, RUNNING TRACKS)
    func applyAnalyses(_ keys: Set<String>) {
        var list = tracks
        var hit: [String] = []
        for key in keys {
            guard let a = analysis.entry(for: key) else { continue }
            if let i = position[key], i < list.count, list[i].key == key {
                if collectionBase[key] == nil, !list[i].ownAnalysis { collectionBase[key] = list[i] }
                let t = a.apply(to: list[i])
                list[i] = t
                byKey[key] = t
                hit.append(key)
            } else if folders.loose[key] != nil {
                folders.applyAnalysis(a, to: key)
            }
        }
        guard !hit.isEmpty else { return }
        replaceRunning(hit)
        smartCache = [:]
        ownCache = [:]
        tracks = list
    }

    /// eigene Analyse verwerfen -> wieder die Werte der Collection (Metadaten-Änderungen bleiben)
    func discardAnalysis(_ keys: [String]) {
        var list = tracks
        var hit: [String] = []
        for key in keys where analysis.entry(for: key) != nil {
            if let b = collectionBase[key], let i = position[key], i < list.count, list[i].key == key {
                var t = b
                t.fileMissing = list[i].fileMissing
                if let e = meta.edit(for: key) { t = e.apply(to: t) } else { collectionBase[key] = nil }
                list[i] = t
                byKey[key] = t
                hit.append(key)
            } else if folders.loose[key] != nil {
                folders.forget(key)
            }
        }
        analysis.remove(keys)
        guard !hit.isEmpty else { return }
        replaceRunning(hit)
        smartCache = [:]
        ownCache = [:]
        tracks = list
    }

    private func replaceRunning(_ keys: some Sequence<String>) {
        let set = Set(keys)
        if running.contains(where: { set.contains($0.key) }) { running = running.map { byKey[$0.key] ?? $0 } }
    }

    /// Schreiben in die Collection-Datei gesammelt nach kurzer Pause (mehrere Übernahmen = ein Schreibvorgang)
    func scheduleWriteBack(after delay: Double = 1.5) {
        writeTask?.cancel()
        writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flushWriteBack()
        }
    }

    /// Konflikte beim Laden (Hintergrund): eigene Änderungen, deren Eintrag sich in der Datei seit der Änderung
    /// geändert hat, weichen der Datei; der eigene Stand kommt in `metadata-konflikt.json` / `edits-konflikt.json`
    nonisolated private static func takeConflicts(_ tracks: [Track], meta: MetadataStore, edits: TrackEditStore?, backupDir: URL?) -> Int {
        let current = Dictionary(tracks.map { ($0.key, $0.entryStamp) }, uniquingKeysWith: { a, _ in a })
        let m = meta.takeConflicts(current: current)
        let e = edits?.takeConflicts(current: current) ?? [:]
        guard !m.isEmpty || !e.isEmpty else { return 0 }
        if let backupDir {
            try? ConflictBackup.save(m, to: backupDir.appendingPathComponent("metadata-konflikt.json"))
            try? ConflictBackup.save(e, to: backupDir.appendingPathComponent("edits-konflikt.json"))
        }
        return Set(m.keys).union(e.keys).count
    }

    /// eigene Hotcues / Grid, die noch nicht in der Datei stehen (gesperrte Einträge: ohne Grid)
    private func pendingCues() -> [String: TrackEdit] {
        guard let edits else { return [:] }
        var out: [String: TrackEdit] = [:]
        for (k, e) in edits.all where e.hasNMLPart {
            guard let i = position[k], i < tracks.count, tracks[i].key == k else { continue }
            var w = e
            if tracks[i].locked { w.bpm = nil; w.gridAnchorMs = nil }
            if w.hasNMLPart { out[k] = w }
        }
        return out
    }

    /// Preparation und eigene History-Sitzungen (neueste zuerst) als Playlists unter `$ROOT/MINOS-741`
    func ownPlaylists() -> [NMLOwnNode] {
        var nodes: [NMLOwnNode] = [.playlist("Preparation", preparation)]
        var sessions: [NMLOwnNode] = []
        if let h = history, !h.live.isEmpty {
            let s = HistorySession(url: h.liveURL, date: h.sessionStart, source: .live)
            sessions.append(.playlist("History " + (s.label ?? HistorySession.dayString(s.date)), h.live.map(\.key)))
        }
        if let h = history {
            for s in h.archive where s.source == .live {
                sessions.append(.playlist("History " + (s.label ?? HistorySession.dayString(s.date)), h.entries(s).map(\.key)))
            }
        }
        if !sessions.isEmpty { nodes.append(.folder("History", sessions)) }
        if playlists.hasPlaylists { nodes.append(.folder(Self.ownPlaylistsFolder, playlists.nmlNodes)) }
        return nodes
    }

    /// alle noch nicht geschriebenen Änderungen in die Collection-Datei: Metadaten, Analysen, Hotcues / Grid,
    /// umbenannte Dateien, neue Einträge (Cuts), eigene Playlists. Sicherung, textgenaues Ersetzen, Prüfung, atomar.
    /// Was geschrieben ist, verlässt metadata.json / edits.json (die Datei hat es jetzt). Datei seit dem letzten Lesen
    /// geändert -> erst neu laden (Konfliktprüfung), dann schreiben
    func flushWriteBack() {
        guard !Session.isSelfTest, let url = sourceURL else { return }
        guard !writing else { scheduleWriteBack(); return }
        let ui = uiPrefs()
        // Zwei-Mac-Modus: nur Mac 1 schreibt in die gemeinsame Collection
        guard ui.writeCollection, !ui.pair.on || ui.pair.writes else { return }
        var job = CollectionWriter.Job(changes: meta.all.mapValues(\.values).filter { position[$0.key] != nil },
                                       analyses: analysis.unwritten.filter { position[$0.key] != nil })
        job.cues = pendingCues()
        job.moves = pendingMoves.filter { entryIndex.raw[$0.key] != nil }
        if ui.writeCuts { job.newEntries = cutStore.tracks.filter { entryIndex.raw[$0.key] == nil && $0.fileExists } }
        if ui.writePlaylists {
            let own = ownPlaylists()
            if own != writtenPlaylists { job.playlists = own }
        }
        guard !job.isEmpty else { return }
        // umbenannte Tracks stehen in MINOS-741 schon unter dem neuen Schlüssel, in der Datei noch unter dem alten
        if !job.moves.isEmpty {
            let old = Dictionary(job.moves.map { ($0.value.key, $0.key) }, uniquingKeysWith: { a, _ in a })
            func rekey<V>(_ d: [String: V]) -> [String: V] { Dictionary(d.map { (old[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a }) }
            job.changes = rekey(job.changes)
            job.analyses = rekey(job.analyses)
            job.cues = rekey(job.cues)
        }
        if Self.collectionSoftwareRunning() {
            status = String(localized: "Collection-Datei nicht geschrieben: die Collection-Software läuft. Änderungen bleiben in MINOS-741.")
            StatusCenter.post(.warning, status, key: "writeback")
            return
        }
        if let s = loadedStamp, FileStamp(url: url) != s {
            writeAfterLoad = true
            status = String(localized: "Collection-Datei inzwischen geändert: erst neu laden, dann schreiben")
            StatusCenter.post(.info, status, detail: url.path, key: "writeback")
            load(url)
            return
        }
        job.expected = loadedStamp
        writing = true
        let index = entryIndex
        let backupDir = url.deletingLastPathComponent().appendingPathComponent("Backup MINOS-741")
        let sent = job
        Task.detached(priority: .utility) {
            let result = Result { try CollectionWriter.write(url: url, job: sent, index: index, backupDir: backupDir) }
            await MainActor.run { self.finishWrite(result, url: url) }
        }
    }

    private func finishWrite(_ result: Result<CollectionWriter.Result, Error>, url: URL) {
        writing = false
        switch result {
        case var .success(r):
            // Schlüssel wie in MINOS-741 (umbenannt = neuer Schlüssel)
            if !r.moved.isEmpty {
                func rekey<V>(_ d: [String: V]) -> [String: V] { Dictionary(d.map { (r.moved[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a }) }
                r.written = rekey(r.written)
                r.writtenCues = rekey(r.writtenCues)
                r.writtenAnalyses = r.writtenAnalyses.map { r.moved[$0] ?? $0 }
            }
            entryIndex.remove(r.moved.keys)
            entryIndex.update(r.blocks)
            if let s = r.stamp { loadedStamp = s }
            meta.clear(written: r.written)
            analysis.markWritten(r.writtenAnalyses)
            for k in r.written.keys where analysis.entry(for: k) == nil { collectionBase[k] = nil }
            let ownGrid = Set(r.writtenCues.keys.filter { k in analysis.entry(for: k).map { $0.bpm != nil || $0.gridAnchorMs != nil } ?? false })
            edits?.clearWritten(r.writtenCues, keepGrid: ownGrid)
            refreshFromFile(r.writtenCues.keys)
            if !r.moved.isEmpty {
                for k in r.moved.keys { pendingMoves[k] = nil }
                saveMoves()
            }
            if r.playlists != nil { writtenPlaylists = r.playlists }
            let n = Set(r.written.keys).union(r.writtenAnalyses).union(r.writtenCues.keys).union(r.moved.keys).count
            var msg = String(localized: "Collection-Datei geschrieben: \(n) Tracks")
            if !r.added.isEmpty { msg += " · " + String(localized: "\(r.added.count) neu") }
            if r.playlistsChanged { msg += " · " + String(localized: "Playlists MINOS-741") }
            if !r.changed { msg = String(localized: "Collection-Datei: schon aktuell") }
            if let b = r.backup { msg += " · " + String(localized: "Sicherung \(b.lastPathComponent)") }
            if !r.missing.isEmpty {
                msg += " · " + String(localized: "\(r.missing.count) nicht gefunden (Datei inzwischen geändert -> ↻ neu laden)")
            }
            status = msg
            StatusCenter.post(r.missing.isEmpty ? .ok : .warning, msg, detail: url.path, key: "writeback")
            // neue / umbenannte Einträge: Liste und Playlists aus der Datei neu
            if !r.added.isEmpty || !r.moved.isEmpty { load(url) }
        case let .failure(e) where e as? CollectionWriter.Refusal == .changedOnDisk:
            writeAfterLoad = true
            load(url)
        case let .failure(e):
            status = String(localized: "Collection-Datei nicht geschrieben: \(String(describing: e))")
            StatusCenter.post(.error, status, detail: url.path, key: "writeback")
        }
    }

    /// Schreibvorgang mit eigenem Auftrag (Entfernen, Zusammenführen): gleiche Sicherungen wie `flushWriteBack`
    /// (Sicherung, Prüfung, atomar, Datei seit dem Lesen geändert -> erst neu laden). Danach eigene Listen auf den
    /// Behalter umbiegen und die Liste neu aus der Datei laden. `done` auf dem Hauptthread: Ergebnis, nil = nicht
    /// geschrieben (Grund steht in der Statuszeile)
    func writeCollection(_ job: CollectionWriter.Job, redirects: [String: String] = [:],
                         done: @escaping @MainActor (CollectionWriter.Result?) -> Void) {
        // Selbsttest schreibt nur Kopien im Temp-Ordner (`CollectionWriter.writeAllowed`, sonst Ablehnung im Schreiben)
        guard let url = sourceURL, CollectionWriter.writeAllowed(url) else { done(nil); return }
        guard !writing else {
            status = String(localized: "Collection-Datei: noch ein Schreibvorgang läuft")
            StatusCenter.post(.info, status, key: "writeback")
            done(nil)
            return
        }
        guard uiPrefs().writeCollection else {
            status = String(localized: "Collection-Datei nicht geschrieben: Schreiben in die Collection ist aus")
            done(nil)
            return
        }
        if Self.collectionSoftwareRunning() {
            status = String(localized: "Collection-Datei nicht geschrieben: die Collection-Software läuft. Änderungen bleiben in MINOS-741.")
            StatusCenter.post(.warning, status, key: "writeback")
            done(nil)
            return
        }
        if let s = loadedStamp, FileStamp(url: url) != s {
            load(url)
            status = String(localized: "Collection-Datei inzwischen geändert: erst neu laden, dann schreiben")
            StatusCenter.post(.info, status, detail: url.path, key: "writeback")
            done(nil)
            return
        }
        var sent = job
        sent.expected = loadedStamp
        writing = true
        let index = entryIndex
        let backupDir = url.deletingLastPathComponent().appendingPathComponent("Backup MINOS-741")
        Task.detached(priority: .utility) {
            let result = Result { try CollectionWriter.write(url: url, job: sent, index: index, backupDir: backupDir) }
            await MainActor.run { self.finishJob(result, url: url, redirects: redirects, done: done) }
        }
    }

    private func finishJob(_ result: Result<CollectionWriter.Result, Error>, url: URL, redirects: [String: String],
                           done: @escaping @MainActor (CollectionWriter.Result?) -> Void) {
        writing = false
        switch result {
        case let .success(r):
            entryIndex.remove(r.removed)
            entryIndex.update(r.blocks)
            if r.changed {
                if let s = r.stamp { loadedStamp = s }
                meta.clear(written: r.written)
                analysis.markWritten(r.writtenAnalyses)
                let ownGrid = Set(r.writtenCues.keys.filter { k in analysis.entry(for: k).map { $0.bpm != nil || $0.gridAnchorMs != nil } ?? false })
                edits?.clearWritten(r.writtenCues, keepGrid: ownGrid)
                redirectOwnLists(removed: Set(r.removed), redirects: redirects)
                var msg = String(localized: "Collection-Datei geschrieben")
                if !r.removed.isEmpty { msg += " · " + String(localized: "\(r.removed.count) entfernt") }
                if r.removedRefs > 0 { msg += " · " + String(localized: "\(r.removedRefs) Playlist-Verweise") }
                if !r.written.isEmpty || !r.writtenCues.isEmpty { msg += " · " + String(localized: "\(Set(r.written.keys).union(r.writtenCues.keys).count) Tracks") }
                if let b = r.backup { msg += " · " + String(localized: "Sicherung \(b.lastPathComponent)") }
                if !r.missing.isEmpty { msg += " · " + String(localized: "\(r.missing.count) nicht gefunden (Datei inzwischen geändert -> ↻ neu laden)") }
                status = msg
                StatusCenter.post(r.missing.isEmpty ? .ok : .warning, msg, detail: url.path, key: "writeback")
                load(url)
            } else {
                status = r.missing.isEmpty ? String(localized: "Collection-Datei: schon aktuell")
                    : String(localized: "\(r.missing.count) Einträge nicht gefunden (Datei inzwischen geändert -> ↻ neu laden)")
                StatusCenter.post(r.missing.isEmpty ? .info : .warning, status, detail: url.path, key: "writeback")
            }
            done(r)
        case let .failure(e) where e as? CollectionWriter.Refusal == .changedOnDisk:
            writeAfterLoad = true
            load(url)
            done(nil)
        case let .failure(e):
            status = String(localized: "Collection-Datei nicht geschrieben: \(String(describing: e))")
            StatusCenter.post(.error, status, detail: url.path, key: "writeback")
            done(nil)
        }
    }

    // MARK: - Playlists der Collection ändern (Datei)

    /// Knoten einer Playlist der Collection (aktueller Baum), nil wenn es ihn nicht (mehr) gibt
    func collectionPlaylist(_ id: UUID) -> PlaylistNode? {
        guard let n = nodes[id], n.kind == .playlist else { return nil }
        return n
    }

    /// Tracks an Position `index` (nil = ans Ende) einer Playlist der Collection einfügen; schon drin = nichts. Rückgängig
    func addToCollectionPlaylist(_ id: UUID, keys: [String], at index: Int? = nil) {
        changeCollectionPlaylist(id, label: String(localized: "Zur Playlist hinzufügen")) { list in
            CollectionPlaylists.inserting(keys, into: list, at: index ?? list.count)
        }
    }

    /// Einträge einer Playlist der Collection in neue Reihenfolge bringen (Ziehen in der Liste). Rückgängig
    func moveInCollectionPlaylist(_ id: UUID, keys: [String], to index: Int) {
        changeCollectionPlaylist(id, label: String(localized: "Reihenfolge ändern")) { list in
            CollectionPlaylists.moving(keys, in: list, to: index)
        }
    }

    /// Neue Liste einer Collection-Playlist: nur mit geschriebenen Änderungen in der Datei (Sicherung, Prüfung, atomar).
    /// Ist Schreiben in die Collection aus, steht der Weg dorthin in der Statuszeile; ohne Änderung kommt nichts
    private func changeCollectionPlaylist(_ id: UUID, label: String, _ transform: ([String]) -> [String]) {
        guard let node = collectionPlaylist(id), !node.uuid.isEmpty else {
            StatusCenter.post(.warning, String(localized: "Playlist in der Collection nicht gefunden (Baum neu laden)"), key: "writeback")
            return
        }
        let before = node.trackKeys
        let after = transform(before)
        guard after != before else {
            StatusCenter.post(.info, String(localized: "Schon in „\(node.name)“"), key: "playlist")
            return
        }
        guard uiPrefs().writeCollection else {
            let hint = String(localized: "Playlist „\(node.name)“ nicht geändert: Schreiben in die Collection ist aus. Einstellungen → Collection → „Änderungen in die Collection-Datei schreiben“ einschalten.")
            status = hint
            StatusCenter.post(.warning, hint, key: "writeback")
            return
        }
        writeCollectionOrder(uuid: node.uuid, to: after, label: label, undo: false, before: before)
    }

    /// Reihenfolge einer Collection-Playlist (per UUID) in die Datei schreiben. `undo`: Rückgängig selbst, ohne neuen Schritt
    private func writeCollectionOrder(uuid: String, to keys: [String], label: String, undo: Bool, before: [String]) {
        var job = CollectionWriter.Job()
        job.playlistEdits = [CollectionWriter.PlaylistEdit(uuid: uuid, keys: keys)]
        writeCollection(job) { r in
            guard !undo, let r, r.playlistsEdited.contains(uuid) else { return }
            UndoStack.shared.record(label, before: before, after: keys) { [weak self] b, a, back in
                self?.writeCollectionOrder(uuid: uuid, to: back ? b : a, label: label, undo: true, before: before)
            }
        }
    }

    /// eigene Listen nach Entfernen / Zusammenführen: Verweise auf den Behalter (ohne Dublette), entfallene Einträge weg.
    /// Preparation und der eigene Playlist-Baum; History-Sitzungen kommen beim nächsten Schreiben aus dem Speicher
    private func redirectOwnLists(removed: Set<String>, redirects: [String: String]) {
        guard !removed.isEmpty || !redirects.isEmpty else { return }
        if preparation.contains(where: { removed.contains($0) || redirects[$0] != nil }) {
            var out: [String] = []
            for k in preparation {
                if let n = redirects[k] {
                    if !out.contains(n) { out.append(n) }
                } else if !removed.contains(k) {
                    out.append(k)
                }
            }
            preparation = out
        }
        var tree = playlists
        var touched = false
        for (old, new) in redirects where tree.all.contains(where: { $0.tracks.contains(old) }) {
            tree.renameTrack(old, to: new)
            touched = true
        }
        if !removed.isEmpty {
            for item in tree.all where item.kind == .playlist && item.tracks.contains(where: { removed.contains($0) }) {
                tree.removeTracks(removed, from: item.id)
                touched = true
            }
        }
        if touched { playlists = tree }
    }

    /// Tracks nach dem Schreiben aus ihrem neuen ENTRY-Block (Cues, Grid), darüber die eigenen Werte wie beim Laden
    private func refreshFromFile(_ keys: some Sequence<String>) {
        var list = tracks
        var hit: [Track] = []
        for k in keys {
            guard let i = position[k], i < list.count, list[i].key == k, let block = entryIndex.raw[k],
                  let parsed = try? NMLParser.parse(data: Data(("<NML><COLLECTION>" + block + "</COLLECTION></NML>").utf8)).tracks.first
            else { continue }
            var t = parsed
            t.fileMissing = list[i].fileMissing
            if collectionBase[k] != nil { collectionBase[k] = t }
            if let e = meta.edit(for: k) { t = e.apply(to: t) }
            if let a = analysis.entry(for: k) { t = a.apply(to: t) }
            guard t != list[i] else { continue }
            list[i] = t
            byKey[k] = t
            hit.append(t)
        }
        guard !hit.isEmpty else { return }
        replaceRunning(hit.map(\.key))
        smartCache = [:]
        ownCache = [:]
        tracks = list
        onRefreshed?(hit)
    }

    // MARK: - Datei umbenannt

    /// Datei eines Collection-Tracks hat einen neuen Pfad (z. B. andere Endung nach dem Schneiden): Schlüssel und Pfad
    /// wechseln sofort in MINOS-741 (Metadaten, Analyse, Hotcues, Preparation wandern mit); mit „in die Collection-Datei
    /// schreiben“ ändert der nächste Schreibvorgang LOCATION des Eintrags, sonst bleibt die Umbenennung in
    /// `collection-moves.json` und gilt bei jedem Laden
    func pathChanged(old: String, new: String) {
        guard old != new, let i = tracks.firstIndex(where: { $0.path == old }) else { return }
        let oldKey = tracks[i].key
        let origin = pendingMoves.first { $0.value.key == oldKey }?.key ?? oldKey   // schon einmal umbenannt
        let loc = CollectionWriter.pathChanged(old: old, new: new, oldBlock: entryIndex.raw[origin])
        guard loc.key != oldKey else { return }
        pendingMoves[origin] = loc
        saveMoves()
        meta.rename(from: oldKey, to: loc.key)
        analysis.rename(from: oldKey, to: loc.key)
        RipChecks.shared.store.rename(from: oldKey, to: loc.key)
        edits?.rename(from: oldKey, to: loc.key)
        if collectionBase[oldKey] != nil { collectionBase[loc.key] = collectionBase.removeValue(forKey: oldKey) }
        var list = tracks
        list[i].key = loc.key
        list[i].path = new
        byKey[oldKey] = nil
        byKey[loc.key] = list[i]
        position[oldKey] = nil
        position[loc.key] = i
        smartCache = [:]
        ownCache = [:]
        tracks = list
        if preparation.contains(oldKey) { preparation = preparation.map { $0 == oldKey ? loc.key : $0 } }
        if playlists.all.contains(where: { $0.tracks.contains(oldKey) }) { playlists.renameTrack(oldKey, to: loc.key) }
        if running.contains(where: { $0.key == oldKey }) { running = running.map { $0.key == oldKey ? list[i] : $0 } }
        if uiPrefs().writeCollection { scheduleWriteBack() }
    }

    private static func loadMoves() -> [String: NMLLocation] {
        guard !Session.isSelfTest, let d = try? Data(contentsOf: movesURL),
              let m = try? JSONDecoder().decode([String: NMLLocation].self, from: d) else { return [:] }
        return m
    }

    private func saveMoves() {
        guard !Session.isSelfTest else { return }
        if pendingMoves.isEmpty { try? FileManager.default.removeItem(at: Self.movesURL); return }
        try? JSONEncoder().encode(pendingMoves).write(to: Self.movesURL, options: .atomic)
    }

    func tracks(for source: BrowserSource) -> [Track] {
        switch source {
        case .collection: return tracks
        case .preparation: return preparation.compactMap { track($0) }
        case .running: return running
        case .cuts: return cuts
        case .toolLoops: return toolLoops
        case .ripTodo: return RipChecks.shared.openKeys.compactMap { track($0) }
        case .missing: return missingTracks
        case .daw: return dawTracks
        case .history, .historyLive: return []
        case .prepArchive: return []   // löst BrowserPaneModel über den HistoryStore auf
        case let .own(r): return ownTracks(r.id)
        case let .folder(p): return folders.tracks(in: p, recursive: false, library: self)
        case let .node(old):
            let n = nodes[old.id] ?? old   // Bereich kann noch den Knoten vor dem Neu-Laden halten (gleiche ID)
            switch n.kind {
            case .folder: return []
            case .playlist: return n.trackKeys.compactMap { byKey[$0] }
            case .smartlist:
                if let hit = smartCache[n.id] { return hit }
                let q = (try? SmartQuery.parse(n.query)) ?? .compare(field: "TITLE", op: .eq, value: .text("\u{0}"))
                let ctx = smartContext(background: true)
                let res = tracks.filter { q.matches($0, now: ctx.now, played: ctx.played) }
                smartCache[n.id] = res
                return res
            }
        }
    }
}

enum BrowserSource: Hashable {
    case collection
    case preparation
    case running
    /// geschnittene Dateien (CUTS)
    case cuts
    /// Tool-Loops (Dateien aus CUTS mit dem Tag `tool-loop`)
    case toolLoops
    /// Tracks mit offenem Befund der Rip-Prüfung
    case ripTodo
    /// Tracks ohne Datei (Cloud „fehlt“ bzw. Ladeprüfung); Eintrag unter den Sammlungen, nur mit Anzahl > 0
    case missing
    /// Clips der laufenden DAW (Live-Brücke)
    case daw
    case node(PlaylistNode)
    case historyLive
    case history(HistorySession)
    case prepArchive(HistorySession)
    /// eigener Eintrag im Playlist-Baum (Ordner, Playlist, Smartlist)
    case own(OwnRef)
    /// Ordner aus MUSIC FOLDERS (absoluter Pfad)
    case folder(String)

    var title: String {
        switch self {
        case .collection: "Track Collection"
        case .preparation: "Preparation"
        case .running: "Running Tracks"
        case .cuts: "Cuts"
        case .toolLoops: "Tool-Loops"
        case .ripTodo: "Zu bearbeiten"
        case .missing: "MISSING"
        case .daw: "DAW"
        case let .node(n): n.name
        case .historyLive: "History"
        case let .history(s): "History " + (s.label ?? Theme.dateTimeFormat.string(from: s.date))
        case let .prepArchive(s): "Preparation " + Theme.dateTimeFormat.string(from: s.date)
        case let .own(r): r.name
        case let .folder(p): (p as NSString).lastPathComponent
        }
    }

    var isHistory: Bool {
        switch self {
        case .historyLive, .history: true
        default: false
        }
    }
}

/// Eigene Smartlist früherer Versionen (Name + Regel-Text, UserDefaults `smartlists.custom`): nur noch gelesen,
/// beim ersten Start wandern sie in den Playlist-Baum (PlaylistFile.load)
struct CustomSmartlist: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var query: String

    static func load() -> [CustomSmartlist] {
        guard let d = E2E.defaults.data(forKey: "smartlists.custom"),
              let l = try? JSONDecoder().decode([CustomSmartlist].self, from: d) else { return [] }
        return l
    }
}

/// Browser-Bereiche und welcher zuletzt benutzt wurde (Ziel für Controller-Browse/Load).
@MainActor @Observable
final class BrowserState {
    let paneA = BrowserPaneModel(name: "Basis")
    let paneB = BrowserPaneModel(name: "Layer")
    var activePaneID: UUID?
    /// Wird von Controllern gesetzt, damit die Liste zur Auswahl scrollt
    var scrollRequest: (pane: UUID, track: Track.ID)?
    @ObservationIgnored weak var store: LibraryStore? { didSet { store?.browser = self } }
    @ObservationIgnored weak var history: HistoryStore?
    @ObservationIgnored var separators: () -> String = { " " }

    var activePane: BrowserPaneModel { activePaneID == paneB.id ? paneB : paneA }
    /// Browser groß (Decks ausgeblendet) – Leertaste oder Browse-Knopf am Controller
    var maximized = false { didSet { if maximized != oldValue { ToggleProbe.toggled(maximized) } } }

    func pane(_ i: Int) -> BrowserPaneModel { i == 1 ? paneB : paneA }

    func selectedTrack(pane i: Int? = nil) -> Track? {
        let p = i.map(pane) ?? activePane
        guard let store, let id = p.selection.first else { return nil }
        return store.track(id)
    }

    func moveSelection(by delta: Int, pane i: Int? = nil) {
        guard let store else { return }
        let pane = i.map(self.pane) ?? activePane
        activePaneID = pane.id
        // angezeigte Liste: Encoder-Schritt sortiert nie neu (läuft eine Hintergrund-Liste, gilt noch die alte)
        let rows = pane.shown.isEmpty ? pane.rows(from: store, history: history, separators: separators()) : pane.shown
        guard !rows.isEmpty else { return }
        let current = pane.selection.first.flatMap { id in rows.firstIndex { $0.id == id } } ?? -1
        let next = max(0, min(rows.count - 1, current + delta))
        pane.selection = [rows[next].id]
        scrollRequest = (pane.id, rows[next].id)
    }
}

/// Messung (MIX741_SELFTEST=1 MIX741_BENCH=reload): Collection laden und mehrmals neu laden, beide Browser-Bereiche
/// offscreen in einem nie gezeigten Fenster. Meldet je Ladevorgang die längste Lücke des Hauptthreads (Takt 240 Hz).
@MainActor
enum ReloadBench {
    nonisolated static var requested: Bool { Session.isSelfTest && ProcessInfo.processInfo.environment["MIX741_BENCH"] == "reload" }

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Audio nur auf ein eingebautes Gerät (wie SettingsShot), gespeichertes Setup danach unverändert zurück
        let d = E2E.defaults
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize", "prefs.v1"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        d.setVolatileDomain(["deviceUID": "BuiltInSpeakerDevice", "mixerMode": "Intern", "sampleRate": 0.0, "bufferSize": 0],
                            forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        let store = LibraryStore(), browser = BrowserState(), history = HistoryStore()
        browser.store = store
        browser.history = history
        let root = HSplitView {
            BrowserPane(model: browser.paneA)
            BrowserPane(model: browser.paneB)
        }
        .environment(store).environment(mix).environment(browser)
        .environment(ControllerStatus()).environment(WaveformCache()).environment(history)
        let host = NSHostingView(rootView: root)
        let rect = NSRect(x: 0, y: 0, width: 1600, height: 700)
        let win = NSWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = host
        host.frame = rect
        func log(_ s: String) { print("[bench] \(s)"); fflush(stdout) }
        var last = CACurrentMediaTime(), worst = 0.0
        let tick = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let now = CACurrentMediaTime()
            worst = max(worst, now - last)
            if now - last > 0.03 { print(String(format: "[hitch] %.3f: %.0f ms", now, (now - last) * 1000)) }
            last = now
        }
        RunLoop.main.add(tick, forMode: .common)
        Task { @MainActor in
            let rounds = Int(ProcessInfo.processInfo.environment["MIX741_BENCH_N"] ?? "") ?? 5
            var gaps: [Double] = []
            let probe = AudioProbe(core: mix.core)
            for i in 0...rounds {
                let rev = store.revision
                try? await Task.sleep(for: .milliseconds(300))
                if i == 1, let t = store.tracks.first(where: { $0.bpm > 0 && $0.fileExists && $0.duration > 120 }) {
                    // ab dem ersten Neu-Laden spielt Deck A (stumm): Audio und Steuer-Thread dürfen nicht hängen
                    mix.core.load(t, deck: 0)
                    while mix.core.trackAudio(0) == nil { try? await Task.sleep(for: .milliseconds(50)) }
                    mix.core.togglePlay(0)
                    try? await Task.sleep(for: .milliseconds(300))
                    probe.start()
                }
                probe.reset()
                worst = 0
                let t0 = CACurrentMediaTime()
                // MIX741_BENCH_ALT=<nml>: abwechselnd eine geänderte Kopie laden (Neu-Laden mit echten Änderungen)
                let alt = ProcessInfo.processInfo.environment["MIX741_BENCH_ALT"].map { URL(fileURLWithPath: $0) }
                store.load(i % 2 == 1 ? alt ?? LibraryStore.defaultNML : LibraryStore.defaultNML)
                while store.revision == rev { try? await Task.sleep(for: .milliseconds(5)) }
                try? await Task.sleep(for: .milliseconds(800))
                let gap = worst * 1000
                if i > 0 { gaps.append(gap) }
                log(String(format: "%@ %d: %d tracks, fertig nach %.2f s, längste Lücke Hauptthread %.0f ms%@",
                           i == 0 ? "laden" : "neu laden", i, store.tracks.count, CACurrentMediaTime() - t0 - 0.8, gap,
                           i == 0 ? "" : probe.report()))
            }
            let s = gaps.sorted()
            log(String(format: "→ neu laden: median %.0f ms, max %.0f ms (n=%d)", s[s.count / 2], s.last ?? 0, s.count))
            mix.core.togglePlay(0)
            exit(0)
        }
        app.run()
        exit(0)
    }
}

/// Messung: Steuer-Queue (Rundlauf eines leeren Blocks) und Wiedergabe-Position von Deck A neben der Uhr, alle 5 ms
/// auf einem eigenen Thread – beides darf beim Laden der Collection nicht stehen bleiben.
final class AudioProbe: @unchecked Sendable {
    private let core: MixController
    private let lock = NSLock()
    private var maxControl = 0.0, maxDrift = 0.0, running = false

    init(core: MixController) { self.core = core }

    func start() {
        guard !running else { return }
        running = true
        Thread.detachNewThread { [self] in
            var lastPos = core.position(0), lastT = CACurrentMediaTime()
            while true {
                Thread.sleep(forTimeInterval: 0.005)
                let t0 = CACurrentMediaTime()
                core.controlQueue.sync {}
                let t1 = CACurrentMediaTime()
                let pos = core.position(0)
                // Abweichung der Position von der Uhr (Tempo 0 %: 1 s Audio je Sekunde); Puffergröße als Rauschen
                let drift = abs((pos - lastPos) - (t1 - lastT))
                lastPos = pos; lastT = t1
                lock.lock()
                maxControl = max(maxControl, t1 - t0)
                maxDrift = max(maxDrift, drift)
                lock.unlock()
            }
        }
    }

    func reset() { lock.lock(); maxControl = 0; maxDrift = 0; lock.unlock() }

    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        guard running else { return "" }
        return String(format: " · steuer-queue max %.1f ms · audio-position max %.1f ms neben der uhr", maxControl * 1000, maxDrift * 1000)
    }
}
