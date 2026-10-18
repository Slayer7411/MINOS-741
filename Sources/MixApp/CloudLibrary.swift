import AppKit
import Observation
import LibraryCloud
import MixCore
import MixEngine

/// Was MINOS-741 lokal hält, solange es läuft
enum CloudKeepMode: String, CaseIterable, Codable, Identifiable {
    case off = "Aus"
    case sets = "Preparation + offene Playlists + Decks"
    case library = "Ganze Library"
    var id: String { rawValue }
}

struct CloudPrefs: Codable, Equatable {
    var keepMode = CloudKeepMode.sets
    /// gleichzeitige Downloads beim Bereitmachen
    var parallel = 2
    /// so viel bleibt auf der Platte frei (GB)
    var minFreeGB = 10
    /// beim Beenden offene Downloads beim Anbieter anfordern (laufen ohne MINOS-741 weiter)
    var handOffOnQuit = true
}

/// Ergebnis des Set-Checks
struct SetCheckResult: Equatable {
    var checked = 0
    var cloud: [Track] = []
    var missing: [Track] = []
    var unknown: [Track] = []
    var date = Date()
    var ready: Bool { cloud.isEmpty && missing.isEmpty && unknown.isEmpty }
}

/// Cloud-Library: Zustand je Track (lokal / nur online / fehlt), Bereitmachen, Lokal-halten, Set-Check.
/// Logik im Modul LibraryCloud (ohne App-Abhängigkeiten, später im Datei-Dienst); hier nur Anbindung an
/// Collection, Decks, Statusleiste. Prüfen = stat ohne Materialisierung (14k Tracks ≈ 0,1 s), Downloads fordert
/// der Planer beim Anbieter an (startDownloadingUbiquitousItem) und bestätigt sie per stat.
@MainActor @Observable
final class CloudLibrary {
    static let shared = CloudLibrary()

    /// zählt jede Zustandsänderung (Browser-Spalte, Filter „lokal“)
    private(set) var revision = 0
    private(set) var counts: [CloudState: Int] = [:]
    /// Tracks in Cloud-Ordnern
    private(set) var cloudTracks = 0
    private(set) var lastScan: Date?
    private(set) var scanSeconds = 0.0
    private(set) var scanning = false
    /// Library-Ordner (tiefster Ordner mit 90 % der Cloud-Tracks) und Anbieter
    private(set) var folder: String?
    private(set) var provider: String?
    private(set) var folderStatus: FolderStatus?
    private(set) var checkingFolder = false
    /// Bereitmachen gesamt (ohne Lokal-halten)
    private(set) var progress = FetchProgress()
    /// Lokal-halten: Tracks, die gerade geholt werden oder warten
    private(set) var keepPending = 0
    private(set) var paused = false

    /// Zustände je Pfad; jede Änderung zählt `stateEpoch` hoch (eine Auswertung im Hintergrund gilt nur, wenn sie seit ihrem Start gleich blieb)
    @ObservationIgnored private var states: [String: FileProbe] = [:] { didSet { stateEpoch &+= 1 } }
    @ObservationIgnored private var stateEpoch = 0
    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var paths: [String] = []
    /// NFC-Pfad -> Pfad der Collection (FSEvents liefert die Schreibweise der Platte)
    @ObservationIgnored private var byNormalized: [String: String] = [:]
    @ObservationIgnored private var prefs = CloudPrefs()
    @ObservationIgnored private var keepPaths: Set<String> = []
    @ObservationIgnored private var labels: [String: String] = [:]
    @ObservationIgnored private var watcher: CloudWatcher?
    @ObservationIgnored private var rescanTimer: Timer?
    @ObservationIgnored private var pendingRefresh: Set<String> = []
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var scanAgain = false

    @ObservationIgnored private let fs = SystemCloudFileSystem()
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "minos741.cloud.scan", qos: .utility)
    /// Planer: nur auf `work`
    @ObservationIgnored private let work = DispatchQueue(label: "minos741.cloud", qos: .utility)
    @ObservationIgnored private nonisolated(unsafe) let fetcher: CloudFetcher
    @ObservationIgnored private nonisolated(unsafe) var ticker: DispatchSourceTimer?
    @ObservationIgnored private nonisolated(unsafe) var tickPaused = false

    /// Downloads nur außerhalb des Selbsttests (MIX741_CLOUD_FETCH=1 erlaubt sie dort)
    private let fetchAllowed = !Session.isSelfTest || ProcessInfo.processInfo.environment["MIX741_CLOUD_FETCH"] == "1"

    private init() {
        fetcher = CloudFetcher(fs: SystemCloudFileSystem())
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { CloudLibrary.shared.rescan(quiet: true) }
        }
    }

    // MARK: - Abfragen

    /// Zustand eines Pfads (beobachtet: Zellen zeichnen bei Änderungen neu)
    func state(_ path: String) -> CloudState {
        _ = revision
        guard let s = states[path] else {
            probeLater(path)   // z. B. Datei aus MUSIC FOLDERS, nicht in der Collection
            return .unknown
        }
        return s.state
    }

    /// ohne Beobachtung (Filter im Browser-Zwischenspeicher)
    func isLocal(_ path: String) -> Bool { states[path]?.state == .local }
    /// Zustand ohne Beobachtung und ohne Nachprüfen (Smartlist-Regeln)
    func peek(_ path: String) -> CloudState? { states[path]?.state }
    func isFetching(_ path: String) -> Bool { _ = revision; return active.contains(path) }
    func isQueued(_ path: String) -> Bool { _ = revision; return queued.contains(path) }
    var hasCloudTracks: Bool { cloudTracks > 0 }
    var handOffOnQuit: Bool { prefs.handOffOnQuit }

    /// offene Downloads (Bereitmachen + Lokal-halten)
    var pendingCount: Int { work.sync { fetcher.pendingPaths.count } }

    // MARK: - Collection

    /// nach jedem Laden/Ändern der Collection; prüft neu, wenn sich die Pfade geändert haben
    func collectionChanged(_ tracks: [Track]) {
        let list = tracks.map(\.path)
        guard list != paths else { return }
        paths = list
        byNormalized = Dictionary(list.map { ($0.precomposedStringWithCanonicalMapping, $0) }, uniquingKeysWith: { a, _ in a })
        let cloud = list.filter(CloudPaths.isCloudBacked)
        cloudTracks = cloud.count
        folder = CloudPaths.libraryFolder(cloud)
        provider = folder.flatMap(CloudPaths.providerRoot).map(CloudPaths.providerName)
        let keep = Set(list)
        states = states.filter { keep.contains($0.key) }
        startWatching(CloudPaths.watchRoots(cloud))
        rescan(quiet: false)
        checkFolder()
    }

    /// alle Pfade neu prüfen (Hintergrund, Zeitgrenze je Datei). Übernehmen und Zählen (14k Pfade) im Hintergrund
    func rescan(quiet: Bool = true) {
        guard !paths.isEmpty else { return }
        guard !scanning else { scanAgain = true; return }
        scanning = true
        let list = paths, before = states, epoch = stateEpoch
        scanQueue.async {
            let r = CloudScanner(fs: SystemCloudFileSystem()).scan(list)
            let m = CloudLibrary.mergeScan(before, paths: list, probes: r.probes)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CloudLibrary.shared.applyScan(list, r, quiet: quiet, merged: m, epoch: epoch) }
            }
        }
    }

    /// Ergebnis der Auswertung eines Laufs (pur, auch im Hintergrund)
    struct ScanMerge: Sendable {
        var states: [String: FileProbe]
        var evicted: [String]
        var changed: Bool
        var counts: [CloudState: Int]
    }

    /// wie `merge` + `recount`, aber auf einer Kopie der Zustände; `paths` ist die Liste des Laufs
    nonisolated static func mergeScan(_ before: [String: FileProbe], paths: [String], probes: [FileProbe]) -> ScanMerge {
        var s = before, evicted: [String] = [], changed = false
        for (p, probe) in zip(paths, probes) {
            let old = s[p]
            guard old != probe else { continue }
            // nicht ermittelbar: alten Stand behalten
            if probe.state == .unknown, old != nil { continue }
            if old?.state == .local, probe.state == .cloud { evicted.append(p) }
            s[p] = probe
            changed = true
        }
        var c: [CloudState: Int] = [:]
        for p in paths where CloudPaths.isCloudBacked(p) { c[s[p]?.state ?? .unknown, default: 0] += 1 }
        return ScanMerge(states: s, evicted: evicted, changed: changed, counts: c)
    }

    private func applyScan(_ list: [String], _ r: ScanReport, quiet: Bool, merged m: ScanMerge, epoch: Int) {
        scanning = false
        guard list == paths else { rescan(quiet: quiet); return }
        let evicted: [String]
        if epoch == stateEpoch {
            // Zustände seit dem Start der Prüfung unverändert: Ergebnis aus dem Hintergrund übernehmen
            states = m.states
            if m.changed { revision += 1 }
            counts = m.counts
            evicted = m.evicted
        } else {
            evicted = merge(zip(list, r.probes).map { ($0, $1) })
            recount()
        }
        lastScan = Date()
        scanSeconds = r.seconds
        if scanAgain { scanAgain = false; rescan(quiet: true) }
        let c = counts
        if MixController.debug || Session.isSelfTest {
            print(String(format: "[cloud] %d pfade in %.3f s · lokal %d · nur online %d · fehlen %d · unbekannt %d · zeitgrenze %d%@",
                         list.count, r.seconds, c[.local] ?? 0, c[.cloud] ?? 0, c[.missing] ?? 0, c[.unknown] ?? 0, r.timedOut,
                         r.aborted ? " · abgebrochen" : ""))
            fflush(stdout)
        }
        if r.aborted {
            StatusCenter.post(.warning, String(localized: "Cloud: Prüfung abgebrochen, der Anbieter antwortet nicht"),
                              detail: folder, key: "cloud.scan")
        } else if !quiet, cloudTracks > 0 {
            let online = c[.cloud] ?? 0
            let text = online > 0
                ? String(localized: "Cloud: \(online) Tracks nur online (☁) · \(c[.local] ?? 0) lokal")
                : String(localized: "Cloud: alle \(c[.local] ?? 0) Tracks lokal")
            StatusCenter.post(online > 0 ? .warning : .info, text, detail: folder, key: "cloud.scan")
        }
        reportEvicted(evicted)
        updateKeepQueue()
    }

    /// Zustände übernehmen; liefert Pfade, die von lokal auf nur online gewechselt sind (ausgelagert)
    @discardableResult
    private func merge(_ list: [(String, FileProbe)]) -> [String] {
        var evicted: [String] = []
        var changed = false
        for (p, probe) in list {
            let old = states[p]
            guard old != probe else { continue }
            // nicht ermittelbar: alten Stand behalten
            if probe.state == .unknown, old != nil { continue }
            if old?.state == .local, probe.state == .cloud { evicted.append(p) }
            states[p] = probe
            changed = true
        }
        if changed { revision += 1 }
        return evicted
    }

    private func recount() {
        var c: [CloudState: Int] = [:]
        for p in paths where CloudPaths.isCloudBacked(p) { c[states[p]?.state ?? .unknown, default: 0] += 1 }
        counts = c
    }

    private func reportEvicted(_ evicted: [String]) {
        let mine = evicted.filter(CloudPaths.isCloudBacked)
        guard !mine.isEmpty else { return }
        let kept = mine.filter { prefs.keepMode == .library || keepPaths.contains($0) }
        let text = kept.isEmpty || !fetchAllowed
            ? String(localized: "Cloud: \(mine.count) Tracks ausgelagert, nur noch online (☁)")
            : String(localized: "Cloud: \(mine.count) Tracks ausgelagert, werden neu geladen")
        StatusCenter.post(.warning, text, detail: (mine.first as NSString?)?.lastPathComponent, key: "cloud.evicted")
    }

    // MARK: - FSEvents

    private func startWatching(_ roots: [String]) {
        guard watcher?.roots != roots else { return }
        watcher?.stop()
        watcher = nil
        guard !roots.isEmpty else { return }
        let w = CloudWatcher(roots: roots, latency: 1.0, queue: scanQueue) { changed, all in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CloudLibrary.shared.filesChanged(changed, all: all) }
            }
        }
        if w.start() { watcher = w }
    }

    private func filesChanged(_ changed: [String], all: Bool) {
        if all { rescan(quiet: true); return }
        for p in changed {
            if let mine = byNormalized[p.precomposedStringWithCanonicalMapping] { pendingRefresh.insert(mine) }
        }
        guard !pendingRefresh.isEmpty, !refreshScheduled else { return }
        refreshScheduled = true
        // gesammelt: ein Download ändert die Datei mehrmals
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { CloudLibrary.shared.refreshPending() }
        }
    }

    /// einzelnen Pfad gesammelt nachprüfen (ohne Beobachtungs-Änderung, darf aus einer View heraus kommen)
    private func probeLater(_ path: String) {
        guard CloudPaths.isCloudBacked(path), pendingRefresh.insert(path).inserted, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { CloudLibrary.shared.refreshPending() }
        }
    }

    private func refreshPending() {
        refreshScheduled = false
        let list = Array(pendingRefresh)
        pendingRefresh = []
        guard !list.isEmpty else { return }
        scanQueue.async {
            let r = CloudScanner(fs: SystemCloudFileSystem(), workers: 2).scan(list)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let lib = CloudLibrary.shared
                    let evicted = lib.merge(zip(list, r.probes).map { ($0, $1) })
                    lib.recount()
                    lib.reportEvicted(evicted)
                    if !evicted.isEmpty { lib.updateKeepQueue() }
                }
            }
        }
    }

    // MARK: - Einstellungen, Decks, Lokal-halten

    func apply(_ p: CloudPrefs) {
        let modeChanged = p.keepMode != prefs.keepMode
        prefs = p
        var c = FetchConfig()
        c.maxParallel = max(1, min(6, p.parallel))
        c.minFreeBytes = Int64(max(1, p.minFreeGB)) << 30
        work.async { [fetcher] in fetcher.config = c }
        if modeChanged {
            if p.keepMode == .off { work.async { [fetcher] in fetcher.cancel(batch: "keep") } }
            updateKeepQueue()
        }
    }

    /// ein Deck lädt -> neue Downloads warten (laufende macht der Anbieter fertig)
    func setPaused(_ on: Bool) {
        guard paused != on else { return }
        paused = on
        work.async { [self] in tickPaused = on }
    }

    /// Tracks aus Preparation, offenen Playlists und Decks (Modus „Preparation + offene Playlists + Decks“)
    func setKeepPaths(_ p: Set<String>) {
        guard p != keepPaths else { return }
        keepPaths = p
        updateKeepQueue()
    }

    private func updateKeepQueue() {
        guard fetchAllowed, prefs.keepMode != .off else { return }
        let want = prefs.keepMode == .library ? Set(paths) : keepPaths
        let items = want.filter { states[$0]?.state == .cloud }.sorted().map { FetchItem(path: $0, size: states[$0]?.size ?? 0) }
        guard !items.isEmpty else { return }
        enqueue(items, batch: "keep", label: String(localized: "Lokal halten"), priority: .keep)
    }

    /// vor dem Laden ins Deck: Datei nur online -> sofort anfordern (Vorrang vor allem), Hinweis in der Statusleiste
    func deckWillLoad(_ t: Track, deck d: Int) {
        guard CloudPaths.isCloudBacked(t.path) else { return }
        let probe = fs.probe(t.path)
        merge([(t.path, probe)])
        guard probe.state == .cloud else { return }
        let name = Self.displayName(t)
        StatusCenter.post(.warning, String(localized: "Deck \(deckLetters[d]): Cloud-Datei wird heruntergeladen – \(name)"),
                          detail: t.path, key: "cloud.deck.\(d)")
        enqueue([FetchItem(path: t.path, size: probe.size)], batch: "deck.\(d)", label: name, priority: .deck)
    }

    // MARK: - Bereitmachen

    /// Tracks herunterladen (Auswahl, Playlist, Preparation, alles)
    func makeReady(_ tracks: [Track], label: String) {
        let cloud = tracks.filter { CloudPaths.isCloudBacked($0.path) }
        guard fetchAllowed else { return }
        let todo = cloud.filter { states[$0.path]?.state != .local }
        guard !todo.isEmpty else {
            StatusCenter.post(.ok, String(localized: "Cloud: alles lokal – \(label)"), key: "cloud.fetch")
            return
        }
        enqueue(todo.map { FetchItem(path: $0.path, size: states[$0.path]?.size ?? 0) },
                batch: "user.\(UUID().uuidString)", label: label, priority: .user)
    }

    func cancelUserDownloads() {
        work.async { [fetcher] in
            for id in fetcher.batchIDs where id.hasPrefix("user.") { fetcher.cancel(batch: id) }
            let snap = Self.snapshot(fetcher)
            DispatchQueue.main.async { MainActor.assumeIsolated { CloudLibrary.shared.applyTick([], snap) } }
        }
        StatusCenter.post(.info, String(localized: "Cloud: Downloads abgebrochen"), key: "cloud.fetch")
    }

    private func enqueue(_ items: [FetchItem], batch: String, label: String, priority: FetchPriority) {
        guard fetchAllowed else { return }
        labels[batch] = label
        work.async { [self] in
            fetcher.enqueue(items, batch: batch, label: label, priority: priority)
            startTicking()
        }
    }

    // MARK: - Takt (auf `work`)

    private struct Snapshot: Sendable {
        var active: Set<String>
        var queued: Set<String>
        var overall: FetchProgress
        var keepPending: Int
        var done: [(String, FetchProgress)]
    }

    private nonisolated func startTicking() {
        guard ticker == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [self] in tick() }
        ticker = t
        t.resume()
    }

    private nonisolated func tick() {
        let events = fetcher.tick(now: Date(), paused: tickPaused)
        let snap = Self.snapshot(fetcher)
        for (id, _) in snap.done { fetcher.forget(batch: id) }
        if fetcher.isIdle {
            ticker?.cancel()
            ticker = nil
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { CloudLibrary.shared.applyTick(events, snap) } }
    }

    private nonisolated static func snapshot(_ f: CloudFetcher) -> Snapshot {
        let done = f.batchIDs.compactMap { id in f.progress(id).flatMap { $0.isDone ? (id, $0) : nil } }
        let keep = f.progress("keep")
        return Snapshot(active: f.activePaths, queued: Set(f.queuedPaths), overall: f.overall(minPriority: .user),
                        keepPending: keep.map { $0.total - $0.finished } ?? 0, done: done)
    }

    @ObservationIgnored private var lastSnap: (Set<String>, Set<String>) = ([], [])

    private func applyTick(_ events: [FetchEvent], _ snap: Snapshot) {
        var updates: [(String, FileProbe)] = []
        for e in events {
            let size = states[e.path]?.size ?? 0
            switch e.outcome {
            case .ready, .alreadyLocal: updates.append((e.path, FileProbe(.local, size: size)))
            case .missing: updates.append((e.path, FileProbe(.missing)))
            default: break
            }
        }
        let fetchChanged = lastSnap != (snap.active, snap.queued)
        active = snap.active
        queued = snap.queued
        lastSnap = (snap.active, snap.queued)
        merge(updates)
        if fetchChanged { revision += 1 }
        if !updates.isEmpty { recount() }
        if keepPending != snap.keepPending { keepPending = snap.keepPending }
        if progress != snap.overall { progress = snap.overall }

        // Deck-Downloads: Meldung ersetzen
        for e in events {
            for b in e.batches where b.hasPrefix("deck.") {
                let d = Int(b.dropFirst(5)) ?? 0
                let name = (e.path as NSString).lastPathComponent
                if e.outcome.isSuccess {
                    StatusCenter.post(.ok, String(localized: "Deck \(deckLetters[d]): Cloud-Datei jetzt lokal – \(name)"), detail: e.path, key: "cloud.deck.\(d)")
                } else {
                    StatusCenter.post(.error, String(localized: "Deck \(deckLetters[d]): Cloud-Datei nicht geladen – \(name)"),
                                      detail: Self.describe(e.outcome), key: "cloud.deck.\(d)")
                }
            }
        }

        // Bereitmachen: Fortschritt + Ergebnis
        let user = snap.overall
        let failedNames = events.filter { !$0.outcome.isSuccess && $0.outcome != .cancelled && $0.batches.contains { $0.hasPrefix("user.") } }
        for e in failedNames { failures.append(e) }
        if user.total > 0, !user.isDone {
            let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1e6) }
            var pt = "\(user.finished)/\(user.total)"
            if user.bytesTotal > 0 { pt += " · \(mb(user.bytesDone))/\(mb(user.bytesTotal)) MB" }
            if paused { pt += " · " + String(localized: "pausiert, Deck lädt") }
            let label = currentLabel(snap)
            // nur bei Änderung, sonst alle 2 s (hält die Meldung am Leben)
            let sig = "\(pt)|\(label)"
            guard sig != lastPosted.sig || Date().timeIntervalSince(lastPosted.at) > 2 else { return finishBatches(snap) }
            lastPosted = (sig, Date())
            StatusCenter.post(.info, String(localized: "Cloud: herunterladen – \(label)"),
                              detail: snap.active.sorted().first.map { ($0 as NSString).lastPathComponent },
                              key: "cloud.fetch", progress: user.fraction, progressText: pt,
                              cancel: { CloudLibrary.shared.cancelUserDownloads() })
        }
        finishBatches(snap)
    }

    @ObservationIgnored private var lastPosted: (sig: String, at: Date) = ("", .distantPast)

    private func finishBatches(_ snap: Snapshot) {
        for (id, p) in snap.done where id.hasPrefix("user.") {
            let label = labels.removeValue(forKey: id) ?? p.label
            let ok = p.total - p.failed
            if p.failed == 0 {
                StatusCenter.post(.ok, String(localized: "Cloud: \(ok) Tracks bereit – \(label)"), key: "cloud.fetch")
            } else {
                let first = failures.first.map { "\(($0.path as NSString).lastPathComponent): \(Self.describe($0.outcome))" }
                StatusCenter.post(.warning, String(localized: "Cloud: \(ok) bereit, \(p.failed) nicht – \(label)"), detail: first, key: "cloud.fetch")
            }
            failures = []
        }
        for (id, _) in snap.done where !id.hasPrefix("user.") { labels[id] = nil }
    }

    @ObservationIgnored private var failures: [FetchEvent] = []

    private func currentLabel(_ snap: Snapshot) -> String {
        labels.filter { $0.key.hasPrefix("user.") }.values.sorted().first ?? snap.overall.label
    }

    /// „Artist – Title“, sonst Dateiname
    static func displayName(_ t: Track) -> String {
        let a = t.artist.trimmingCharacters(in: .whitespaces), ti = t.title.trimmingCharacters(in: .whitespaces)
        if a.isEmpty && ti.isEmpty { return (t.path as NSString).lastPathComponent }
        return a.isEmpty ? ti : (ti.isEmpty ? a : "\(a) – \(ti)")
    }

    static func describe(_ o: FetchOutcome) -> String {
        switch o {
        case .ready, .alreadyLocal: String(localized: "lokal")
        case .missing: String(localized: "Datei fehlt")
        case let .failed(why): String(localized: String.LocalizationValue(why))
        case .noSpace: String(localized: "zu wenig freier Platz")
        case .overBudget: String(localized: "Grenze erreicht")
        case .cancelled: String(localized: "abgebrochen")
        }
    }

    // MARK: - Set-Check

    /// Tracks frisch prüfen (Hintergrund, Zeitgrenze je Datei)
    func setCheck(_ tracks: [Track], done: @escaping @MainActor (SetCheckResult) -> Void) {
        var seen = Set<String>()
        let list = tracks.filter { seen.insert($0.key).inserted }
        let paths = list.map(\.path)
        scanQueue.async {
            let r = CloudScanner(fs: SystemCloudFileSystem(), workers: 4, timeout: 3).scan(paths)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let lib = CloudLibrary.shared
                    let evicted = lib.merge(zip(paths, r.probes).map { ($0, $1) })
                    lib.recount()
                    lib.reportEvicted(evicted)
                    var res = SetCheckResult(checked: list.count)
                    for (t, p) in zip(list, r.probes) {
                        switch p.state {
                        case .cloud: res.cloud.append(t)
                        case .missing: res.missing.append(t)
                        case .unknown: res.unknown.append(t)
                        case .local: break
                        }
                    }
                    done(res)
                }
            }
        }
    }

    // MARK: - Ordner beim Anbieter

    func checkFolder() {
        guard let folder, !checkingFolder else { return }
        checkingFolder = true
        scanQueue.async {
            let s = CloudPin.status(of: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CloudLibrary.shared.checkingFolder = false
                    CloudLibrary.shared.folderStatus = s
                }
            }
        }
    }

    func revealFolder() {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    // MARK: - Beenden

    /// offene Downloads beim Anbieter anfordern; sie laufen ohne MINOS-741 weiter (gemessen: Anforderung,
    /// Prozess sofort beendet, 9,6-MB-Datei 2,5 s später lokal). Liefert die Anzahl.
    @discardableResult
    func handOff() -> Int {
        guard fetchAllowed, prefs.handOffOnQuit else { return 0 }
        let n: Int = work.sync { [fetcher, fs] in
            ticker?.cancel()
            ticker = nil
            let q = fetcher.queuedPaths
            for p in q.prefix(5000) { try? fs.requestDownload(p) }
            return q.count + fetcher.activePaths.count
        }
        if n > 0 { print("[cloud] beim Beenden übergeben: \(n) Downloads") }
        return n
    }

    // MARK: - nur Selbsttest-Bild

    /// Zustände setzen (Bilder der Spalte; die echte Library ist ganz lokal)
    func demo(_ list: [(String, CloudState)], fetching: Set<String> = [], queued q: Set<String> = []) {
        guard Session.isSelfTest else { return }
        for (p, s) in list { states[p] = FileProbe(s, size: 12_000_000) }
        active = fetching
        queued = q
        revision += 1
    }
}
