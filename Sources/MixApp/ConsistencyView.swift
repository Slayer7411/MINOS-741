import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MixCore
import LibraryCloud

typealias Check = ConsistencyCheck

/// Zustand des Prüf-Fensters. Holt den Stand des Laufs 20× je Sekunde gebündelt (nie eine Änderung je Datei),
/// zeigt die letzten 2000 Protokollzeilen, behält alle Befunde.
@MainActor @Observable
final class ConsistencyModel {
    static let viewLines = 2000

    var lines: [ConsistencyRun.LogLine] = []
    var findings: [Check.Finding] = []
    var snap = ConsistencyRun.Snapshot()
    var filter: Check.Category?
    var showFindings = false
    var source = ""
    /// gemeinsamer Musik-Ordner der Collection: in Protokoll und Tabelle als „…/“ gekürzt
    var root = ""
    var started = false
    /// DUPLIKATE: Ansicht an, Gruppen mit Plan je Gruppe (gültig für den Stand der Collection), Papierkorb-Schalter
    var showDups = false
    var dups: [DupItem] = []
    var dupsReady = false
    var trashDups = false
    enum Pane { case log, findings, dups }
    var pane: Pane { showDups ? .dups : (showFindings ? .findings : .log) }
    @ObservationIgnored private var run: ConsistencyRun?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastLine = 0
    @ObservationIgnored weak var store: LibraryStore?

    var running: Bool { started && !snap.finished }

    func short(_ path: String) -> String {
        root.count > 1 && path.hasPrefix(root + "/") ? "…" + path.dropFirst(root.count) : path
    }
    /// Befund-Text mit gekürzten Pfaden
    func shortText(_ s: String) -> String { root.count > 1 ? s.replacingOccurrences(of: root + "/", with: "…/") : s }

    func start(store: LibraryStore, musicFolders: Bool) {
        run?.cancel()
        self.store = store
        lines = []; findings = []; snap = ConsistencyRun.Snapshot(); filter = nil; showFindings = false; lastLine = 0
        dupsReady = false; dups = []
        source = store.sourceURL?.path ?? LibraryStore.defaultNML.path
        root = store.folders.defaultRoot ?? ""
        var lists = Check.lists(in: store.root)
        if !store.preparation.isEmpty { lists.append(Check.KeyList(name: "Preparation", keys: store.preparation)) }
        let input = Check.Input(tracks: store.tracks, lists: lists, musicRoots: musicFolders ? store.folders.roots : [])
        snap.total = input.tracks.count
        run = ConsistencyRun.start(input)
        started = true
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func poll() {
        guard let run else { return }
        var s = run.snapshot(sinceLine: lastLine, sinceFinding: findings.count)
        lastLine = s.lastLine
        if !s.lines.isEmpty {
            lines.append(contentsOf: s.lines)
            if lines.count > Self.viewLines { lines.removeFirst(lines.count - Self.viewLines) }
        }
        if !s.findings.isEmpty { findings.append(contentsOf: s.findings) }
        s.lines = []; s.findings = []
        let ended = s.finished && !snap.finished
        snap = s
        if s.finished {
            timer?.invalidate(); timer = nil
            if ended, !findings.isEmpty { showFindings = true }
        }
    }

    /// stoppt sofort (Anzeige), Arbeiter hören vor der nächsten Datei auf
    func cancel() { run?.cancel(); poll() }

    var fraction: Double { snap.total > 0 ? Double(snap.done) / Double(snap.total) : (snap.finished ? 1 : 0) }

    var eta: TimeInterval? {
        guard running, snap.phase == .files, snap.done > 20 else { return nil }
        return snap.elapsed / Double(snap.done) * Double(snap.total - snap.done)
    }

    var visibleFindings: [Check.Finding] {
        let list = filter.map { c in findings.filter { $0.category == c } } ?? findings
        return list.sorted { ($0.category.isProblem ? 0 : 1, $0.category.rawValue, $0.path) < ($1.category.isProblem ? 0 : 1, $1.category.rawValue, $1.path) }
    }

    var summary: Check.Summary {
        Check.Summary(source: source, tracks: snap.total, checked: snap.done, ok: snap.ok, counts: snap.counts,
                      folderFiles: snap.folderFiles, elapsed: snap.elapsed, cancelled: snap.cancelled)
    }

    // MARK: Aktionen

    func save(csv: Bool) {
        let panel = NSSavePanel()
        let day = Theme.dateFormat.string(from: Date())
        panel.nameFieldStringValue = "minos-collection-check-\(day).\(csv ? "csv" : "txt")"
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = csv ? Check.reportCSV(findings: findings) : Check.reportText(summary, findings: findings)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func showInFinder(_ ids: Set<Int>) {
        // Existenzprüfung im Hintergrund (Cloud-Ordner: ein stat kann Sekunden hängen), Finder erst danach
        let paths = findings.filter { ids.contains($0.id) }.map(\.path)
        Task.detached(priority: .userInitiated) {
            let urls = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            var show = urls
            if urls.isEmpty, let first = paths.first {
                // Datei fehlt: nächsten vorhandenen Ordner zeigen
                var dir = (first as NSString).deletingLastPathComponent
                while !dir.isEmpty, dir != "/", !FileManager.default.fileExists(atPath: dir) { dir = (dir as NSString).deletingLastPathComponent }
                show = [URL(fileURLWithPath: dir)]
            }
            let target = show
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(target) }
        }
    }

    func copyPaths(_ ids: Set<Int>) {
        let text = findings.filter { ids.contains($0.id) }.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func canReveal(_ ids: Set<Int>) -> Bool {
        guard let store, let f = findings.first(where: { ids.contains($0.id) }), let k = f.key else { return false }
        return store.byKey[k] != nil
    }

    /// Track im Browser zeigen: aktiver Bereich auf TRACK COLLECTION, Suche/Filter leer, Zeile gewählt
    func reveal(_ ids: Set<Int>) {
        guard let store, let browser = store.browser, let f = findings.first(where: { ids.contains($0.id) }),
              let key = f.key, store.byKey[key] != nil else { return }
        let pane = browser.activePane
        pane.source = .collection
        pane.search = ""
        pane.roles = []
        pane.tags = []
        pane.selection = [key]
        browser.activePaneID = pane.id
        browser.scrollRequest = (pane.id, key)
        MainWindow.window?.makeKeyAndOrderFront(nil)
    }
}

/// Gruppe doppelter Einträge mit ihrem Plan (Vorschau, Zusammenführen)
struct DupItem {
    var reason: String
    var plan: CollectionMerge.Plan
}

extension ConsistencyModel {
    /// Schlüssel der Auswahl, die es in der Collection gibt (ohne Dubletten, Reihenfolge der Befunde)
    func keys(_ ids: Set<Int>, store: LibraryStore) -> [String] {
        var seen = Set<String>()
        return findings.filter { ids.contains($0.id) }.compactMap(\.key).filter { store.byKey[$0] != nil && seen.insert($0).inserted }
    }

    /// Schlüssel der Auswahl mit Befund „Datei fehlt“ (für TIDAL)
    func missingKeys(_ ids: Set<Int>, store: LibraryStore) -> [String] {
        var seen = Set<String>()
        return findings.filter { ids.contains($0.id) && $0.category == .missing }.compactMap(\.key)
            .filter { store.byKey[$0] != nil && seen.insert($0).inserted }
    }

    /// Zeile einer Bestätigung: Artist – Titel · Pfad
    func line(_ t: Track) -> String {
        let name = t.artist.isEmpty && t.title.isEmpty ? t.fileName : "\(t.artist) – \(t.title)"
        return name + " · " + short(t.path)
    }

    /// Verweise auf die Schlüssel in Playlists (Preparation und Playlist-Baum)
    func refCount(_ keys: [String], store: LibraryStore) -> Int {
        let set = Set(keys)
        var n = store.preparation.filter { set.contains($0) }.count
        for l in Check.lists(in: store.root) { n += l.keys.filter { set.contains($0) }.count }
        return n
    }

    /// Schreiben in die Collection erlauben: ist es aus, fragen, ob es für diese Aktion eingeschaltet wird
    func ensureWrite(_ store: LibraryStore, then: @escaping () -> Void) {
        if store.uiPrefs().writeCollection { then(); return }
        CheckConfirm.ask(String(localized: "Schreiben in die Collection ist aus"),
                         info: [String(localized: "Diese Aktion schreibt in die Collection-Datei. Schreiben ist in den Einstellungen aus.")],
                         sample: [], action: String(localized: "Einschalten und weiter"), destructive: false) {
            store.updateUIPrefs { $0.writeCollection = true }
            then()
        }
    }

    /// in den Papierkorb, nie löschen; nur Dateien, die es gibt
    static func trash(_ paths: [String]) {
        Task {
            // Existenz im Hintergrund (Cloud-Ordner), der Papierkorb danach auf dem Hauptthread
            let urls = await FileExistence.existing(Array(Set(paths))).map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return }
            let n = urls.count
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error {
                    StatusCenter.post(.error, String(localized: "Papierkorb: \(error.localizedDescription)"), key: "trash")
                } else {
                    StatusCenter.post(.ok, String(localized: "\(n) Dateien in den Papierkorb"), key: "trash")
                }
            }
        }
    }

    /// Entfernen (mit oder ohne Dateien) nach Bestätigung
    func askRemove(_ ids: Set<Int>, store: LibraryStore, trash: Bool) {
        let keys = keys(ids, store: store)
        let tracks = keys.compactMap { store.byKey[$0] }
        guard !tracks.isEmpty else {
            StatusCenter.post(.info, String(localized: "keine Collection-Einträge in der Auswahl"), key: "writeback")
            return
        }
        let refs = refCount(keys, store: store)
        // Dateien prüfen im Hintergrund (Cloud-Ordner), die Bestätigung danach
        Task {
            let present = Set(await FileExistence.existing(tracks.map(\.path)))
            let files = tracks.filter { present.contains($0.path) }
            var info = [String(localized: "\(tracks.count) Einträge aus der Collection"),
                        String(localized: "\(refs) Verweise in Playlists fallen weg")]
            if trash {
                info.append(String(localized: "\(files.count) Dateien in den Papierkorb"))
                let cloud = files.filter { CloudPaths.isCloudBacked($0.path) }.count
                if cloud > 0 { info.append(String(localized: "\(cloud) davon im Cloud-Ordner: nur der lokale Platzhalter geht in den Papierkorb")) }
            } else {
                info.append(String(localized: "Dateien bleiben liegen"))
            }
            let title = trash ? String(localized: "Aus Collection entfernen + Dateien?") : String(localized: "Aus Collection entfernen?")
            self.ensureWrite(store) {
                CheckConfirm.ask(title, info: info, sample: tracks.map { self.line($0) },
                                 action: trash ? String(localized: "Entfernen + Papierkorb") : String(localized: "Entfernen")) {
                    store.writeCollection(CollectionMerge.removalJob(keys: keys)) { r in
                        guard let r, r.changed else { return }
                        let gone = Set(r.removed)
                        self.findings.removeAll { f in f.key.map { gone.contains($0) } ?? false }
                        if trash { Self.trash(tracks.filter { gone.contains($0.key) }.map(\.path)) }
                    }
                }
            }
        }
    }

    /// Analyse der Auswahl (wie das Menü der Track-Tabelle)
    func analyse(_ ids: Set<Int>, store: LibraryStore) {
        let tracks = keys(ids, store: store).compactMap { store.byKey[$0] }
        guard !tracks.isEmpty else { return }
        Analyses.shared.enqueue(tracks, refresh: false)
    }

    /// Fehlende Dateien der Auswahl bei TIDAL suchen (derselbe Ablauf wie „Fehlende → TIDAL“)
    func tidal(_ ids: Set<Int>, store: LibraryStore) {
        let tracks = missingKeys(ids, store: store).compactMap { store.byKey[$0] }
        guard !tracks.isEmpty else { return }
        let ui = store.uiPrefs()
        TidalSyncModel.shared.start(tracks: tracks, clientID: ui.tidalClientID, pattern: ui.tidalPlaylistPattern)
    }

    /// Doppelte suchen (Gruppen und Pläne) aus dem Stand der Collection
    func computeDups(store: LibraryStore) {
        let sep = store.uiPrefs().tagSeparators
        var items: [DupItem] = []
        for g in CollectionMerge.groups(store.tracks) {
            let ranked = CollectionMerge.ranked(g.keys.compactMap { store.byKey[$0] })
            guard ranked.count > 1 else { continue }
            items.append(DupItem(reason: g.reason, plan: CollectionMerge.plan(keeper: ranked[0], others: Array(ranked.dropFirst()), separators: sep)))
        }
        dups = items
        dupsReady = true
    }

    /// Zusammenführen aller Gruppen nach Bestätigung; Dateien nur mit „+ Dateien“, nie die des Behalters
    func askMerge(_ store: LibraryStore, trash: Bool) {
        let plans = dups.map(\.plan)
        guard !plans.isEmpty else { return }
        let removed = plans.flatMap(\.removed)
        let keepers = Set(plans.map { MusicFolder.match($0.keeper.path) })
        var seen = Set<String>()
        var trashList: [(key: String, path: String)] = []
        if trash {
            for t in removed where !t.path.isEmpty {
                let m = MusicFolder.match(t.path)
                if !keepers.contains(m), seen.insert(m).inserted { trashList.append((t.key, t.path)) }
            }
        }
        let refs = refCount(removed.map(\.key), store: store)
        var info = [String(localized: "\(plans.count) Gruppen, \(removed.count) Einträge fallen aus der Collection"),
                    String(localized: "Tags, Bewertung, Abspielungen, Farbe, Cues und Grid gehen in den Behalter"),
                    String(localized: "\(refs) Verweise in Playlists zeigen auf den Behalter")]
        info.append(trash ? String(localized: "\(trashList.count) Dateien in den Papierkorb (nie die des Behalters)")
                          : String(localized: "Dateien bleiben liegen"))
        let sample = plans.map { "\(short($0.keeper.path))  ← \($0.removed.count)" }
        ensureWrite(store) {
            CheckConfirm.ask(String(localized: "Duplikate zusammenführen?"), info: info, sample: sample,
                             action: String(localized: "Zusammenführen")) {
                let job = CollectionMerge.job(for: plans)
                store.writeCollection(job, redirects: job.redirects) { r in
                    guard let r, r.changed else { return }
                    let gone = Set(r.removed)
                    self.dups = []
                    self.dupsReady = false
                    self.findings.removeAll { f in f.key.map { gone.contains($0) } ?? false }
                    if trash { Self.trash(trashList.filter { gone.contains($0.key) }.map(\.path)) }
                }
            }
        }
    }

    /// Vorschau eines Plans: was der Behalter bekommt, was entfällt
    func preview(_ p: CollectionMerge.Plan) -> String {
        let none = "–"
        var l = [String(localized: "behalten") + "   " + short(p.keeper.path)]
        l += p.removed.map { String(localized: "entfällt") + "   " + short($0.path) }
        let tags = p.keeper.comment2.isEmpty ? none : p.keeper.comment2
        l.append("tags       " + (p.changes[.comment2].map { tags + " → " + $0 } ?? tags))
        if let c = p.changes[.comment] { l.append(String(localized: "kommentar") + "  " + c) }
        l.append(String(localized: "bewertung") + "  \(p.keeper.rating) → \(p.result.rating)")
        l.append("plays      \(p.keeper.playCount) → \(p.result.playCount)")
        if let c = p.color { l.append(String(localized: "farbe") + "       \(c)") }
        if let g = p.grid?.gridAnchorMs { l.append("grid       " + String(localized: "übernommen") + ", " + String(localized: "anker") + " \(Theme.time(g / 1000))") }
        let hot = p.result.hotcues
        if !hot.isEmpty {
            l.append("hotcues    " + hot.map { "\($0.hotcue + 1):" + Theme.time($0.startMs / 1000) + ($0.kind == .loop ? " loop" : "") }.joined(separator: "  "))
        }
        if !p.memoryCues.isEmpty {
            l.append("memory     +\(p.memoryCues.count) " + p.memoryCues.map { Theme.time($0.startMs / 1000) + ($0.kind == .loop ? " loop" : "") }.joined(separator: "  "))
        }
        return l.joined(separator: "\n")
    }
}

/// Bestätigung vor jeder Änderung an der Collection oder an Dateien: Anzahl, Liste (erste 10). „Abbrechen“ ist der
/// Standard (Return und Esc). Als Blatt am Prüf-Fenster.
@MainActor
enum CheckConfirm {
    static func ask(_ title: String, info: [String], sample: [String], action: String, destructive: Bool = true,
                    then: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = title
        var text = info.joined(separator: "\n")
        if !sample.isEmpty {
            text += "\n\n" + sample.prefix(10).joined(separator: "\n")
            if sample.count > 10 { text += "\n" + String(localized: "… und \(sample.count - 10) weitere") }
        }
        a.informativeText = text
        a.alertStyle = destructive ? .warning : .informational
        a.addButton(withTitle: String(localized: "Abbrechen"))
        a.addButton(withTitle: action)
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .alertSecondButtonReturn { then() } }
        if let w = ConsistencyWindow.window, w.isVisible { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }
}

/// Menü aus Aktionen: jede Aktion hält ihr Ziel selbst (das Menü hält nur schwache Verweise)
@MainActor
enum CheckMenu {
    final class Box: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    /// nil = Trennlinie
    static func build(_ items: [(String, Bool, () -> Void)?]) -> NSMenu {
        let m = NSMenu()
        for item in items {
            guard let (title, enabled, run) = item else { m.addItem(.separator()); continue }
            let box = Box(run)
            let mi = NSMenuItem(title: title, action: #selector(Box.fire), keyEquivalent: "")
            mi.target = box
            mi.representedObject = box
            mi.isEnabled = enabled
            m.addItem(mi)
        }
        return m
    }
}

/// Fenster „Collection prüfen“: eines je App, schließen bricht einen laufenden Prüflauf ab.
@MainActor
enum ConsistencyWindow {
    static var window: NSWindow?
    private static let model = ConsistencyModel()
    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { ConsistencyWindow.model.cancel() }
        }
    }
    private static let delegate = Delegate()

    /// öffnen und (wenn noch nicht gelaufen oder fertig) prüfen
    static func show(store: LibraryStore, restart: Bool = true) {
        if let w = window, w.isVisible, model.started {   // schon offen: nur nach vorn, Ergebnis bleibt
            w.makeKeyAndOrderFront(nil)
            return
        }
        if window == nil {
            let host = NSHostingView(rootView: ConsistencyView(model: model, musicFolders: { AppPrefs.load().ui.checkMusicFolders })
                .environment(store).zoomExempt())
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = String(localized: "Collection prüfen")
            w.contentView = host
            w.contentMinSize = NSSize(width: 760, height: 520)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Theme.void)
            w.delegate = delegate
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        if restart, !model.running, !store.tracks.isEmpty {
            model.start(store: store, musicFolders: AppPrefs.load().ui.checkMusicFolders)
        }
    }
}

struct ConsistencyView: View {
    @Bindable var model: ConsistencyModel
    let musicFolders: () -> Bool
    @Environment(LibraryStore.self) private var store
    @State private var selection: Set<Int> = []
    @State private var dupSelection: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            progress
            counters
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 4) {
                DeckButton(title: "LOG", active: model.pane == .log) { model.showDups = false; model.showFindings = false }
                DeckButton(title: String(localized: "BEFUNDE \(model.findings.count)"), active: model.pane == .findings) {
                    model.showDups = false
                    model.showFindings = true
                }
                DeckButton(title: model.dupsReady ? String(localized: "DUPLIKATE \(model.dups.count)") : "DUPLIKATE", active: model.pane == .dups) {
                    model.showDups = true
                    if !model.dupsReady { model.computeDups(store: store) }
                }
                if model.pane == .findings, let f = model.filter {
                    DeckButton(title: f.tag.trimmingCharacters(in: .whitespaces) + " ✕", active: true, color: color(f)) { model.filter = nil }
                }
                Spacer()
                if model.lines.count >= ConsistencyModel.viewLines {
                    Text("letzte \(ConsistencyModel.viewLines) zeilen · alle befunde unter BEFUNDE").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
            }
            switch model.pane {
            case .log: log
            case .findings: VStack(alignment: .leading, spacing: 6) { findingsActions; findingsTable }
            case .dups: dupsPane
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.void)
        .foregroundStyle(Theme.bone)
        .preferredColorScheme(.dark)
    }

    // MARK: Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("◆ COLLECTION PRÜFEN").font(Theme.label(18, .bold))
                Spacer()
                badge
            }
            Text("\(URL(fileURLWithPath: model.source).lastPathComponent) · \(model.snap.total) tracks · nur lesen, es wird nichts geändert")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            if !model.root.isEmpty {
                Text("… = \(model.root)").font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var badge: some View {
        let (text, bg): (String, Color) = !model.started ? ("BEREIT", Theme.hairline)
            : model.snap.cancelled ? ("ABGEBROCHEN", Theme.state)
            : model.snap.finished ? ("FERTIG", Theme.bone)
            : ("LÄUFT", Theme.secondary)
        return Text(LocalizedStringKey(text)).font(Theme.label(11, .bold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(bg == Theme.bone ? Theme.void : Theme.bone)
            .background(bg)
    }

    private var phaseText: String {
        switch model.snap.phase {
        case .files: String(localized: "DATEIEN")
        case .playlists: String(localized: "PLAYLISTS")
        case .folders: String(localized: "MUSIC FOLDERS · \(model.snap.folderFiles) dateien")
        case .done: model.snap.cancelled ? String(localized: "ABGEBROCHEN") : String(localized: "FERTIG")
        }
    }

    private var progress: some View {
        let s = model.snap
        let width = 64
        let filled = Int((model.fraction * Double(width)).rounded(.down))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: max(0, width - filled))
        var info = "\(s.done) / \(s.total) · \(Int((model.fraction * 100).rounded(.down))) % · \(Theme.time(s.elapsed))"
        if let eta = model.eta { info += " · " + String(localized: "noch ~\(Theme.time(eta))") }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(bar).font(Theme.mono(12)).foregroundStyle(s.cancelled ? Theme.state : Theme.bone).lineLimit(1)
                Text(phaseText).font(Theme.label(11, .bold)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Text(info).font(Theme.mono(11)).monospacedDigit()
            Text("› " + (s.current.isEmpty ? (s.finished ? summaryLine : "…") : model.short(s.current)))
                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private var summaryLine: String {
        let s = model.snap
        let problems = Check.Category.allCases.filter(\.isProblem).reduce(0) { $0 + (s.counts[$1] ?? 0) }
        let hints = Check.Category.allCases.filter { !$0.isProblem }.reduce(0) { $0 + (s.counts[$1] ?? 0) }
        return String(localized: "\(s.ok) ok · \(problems) probleme · \(hints) hinweise · \(Theme.time(s.elapsed))")
    }

    // MARK: Zähler

    private var counters: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), alignment: .leading, spacing: 4) {
            counter(nil)
            ForEach(Check.Category.allCases, id: \.self) { counter($0) }
        }
    }

    private func counter(_ c: Check.Category?) -> some View {
        let n = c.map { model.snap.counts[$0] ?? 0 } ?? model.snap.ok
        let tint = c.map { n > 0 ? color($0) : Theme.muted } ?? Theme.bone
        let selected = c != nil && model.filter == c && model.showFindings
        return Button {
            guard let c else { return }
            model.filter = model.filter == c && model.showFindings ? nil : c
            model.showDups = false
            model.showFindings = true
        } label: {
            HStack(spacing: 6) {
                Text(c?.tag ?? "OK  ").font(Theme.mono(11, .bold)).foregroundStyle(tint)
                Text("\(n)").font(Theme.mono(11)).monospacedDigit().foregroundStyle(n > 0 ? Theme.bone : Theme.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(selected ? Theme.chitinRaised : Theme.chitin)
            .overlay(Rectangle().stroke(selected ? tint : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.map(label) ?? String(localized: "Tracks ohne Befund"))
    }

    private func color(_ c: Check.Category) -> Color { c.isProblem ? Theme.state : Theme.secondary }

    private func label(_ c: Check.Category) -> String {
        switch c {
        case .missing: String(localized: "Datei fehlt")
        case .unreadable: String(localized: "keine Leserechte")
        case .empty: String(localized: "Datei ist leer (0 Byte)")
        case .badAudio: String(localized: "kein lesbares Audio")
        case .duration: String(localized: "Dauer weicht mehr als 2 s von der Collection ab")
        case .pathCase: String(localized: "Pfad auf der Platte in anderer Groß-/Kleinschreibung")
        case .unicodeForm: String(localized: "gleicher Name, andere Unicode-Form (NFC/NFD) – auf dem Mac ohne Folgen")
        case .name: String(localized: "Dateiname enthält weder Titel noch Artist")
        case .dupPath: String(localized: "gleiche Datei mehrfach in der Collection")
        case .dupTrack: String(localized: "gleicher Artist + Titel, andere Datei")
        case .noAnalysis: String(localized: "Analyse fehlt (BPM, Grid, Key, Lautheit)")
        case .grid: String(localized: "Grid: BPM außerhalb 60–200 oder Anker hinter dem Ende")
        case .dangling: String(localized: "Playlist-Eintrag ohne Track in der Collection")
        case .notInCollection: String(localized: "Datei im Musik-Ordner, nicht in der Collection")
        }
    }

    // MARK: Protokoll

    private var log: some View {
        LogTextView(lines: model.lines, tail: model.running, short: model.short, shortText: model.shortText)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    // MARK: Befunde

    private var findingsTable: some View {
        let rows = model.visibleFindings.map { f in
            CheckRow(id: f.id, cells: [f.category.tag.trimmingCharacters(in: .whitespaces), model.short(f.path), model.shortText(f.detail)],
                     tint: NSColor(color(f.category)))
        }
        return CheckTable(rows: rows,
                          columns: [CheckColumn(title: "", width: 40, minWidth: 30), CheckColumn(title: String(localized: "Pfad"), width: 520, minWidth: 200),
                                    CheckColumn(title: String(localized: "Befund"), width: 320, minWidth: 120, muted: true)],
                          selected: selection, onSelect: { selection = $0 },
                          onActivate: { ids in if model.canReveal(ids) { model.reveal(ids) } else { model.showInFinder(ids) } },
                          menu: { ids in findingsMenu(ids) })
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    /// Aktionen auf die gewählten Befunde (Knöpfe; dieselben wie im Rechtsklick-Menü)
    private var findingsActions: some View {
        let ids = selection
        let keys = model.keys(ids, store: store)
        let missing = model.missingKeys(ids, store: store)
        return HStack(spacing: 4) {
            DeckButton(title: "AUS COLLECTION ENTFERNEN") { model.askRemove(ids, store: store, trash: false) }.disabled(keys.isEmpty)
            DeckButton(title: "+ DATEIEN IN DEN PAPIERKORB", color: Theme.bone) { model.askRemove(ids, store: store, trash: true) }
                .disabled(keys.isEmpty)
            DeckButton(title: "ANALYSIEREN") { model.analyse(ids, store: store) }.disabled(keys.isEmpty)
            DeckButton(title: "FEHLENDE → TIDAL") { model.tidal(ids, store: store) }.disabled(missing.isEmpty)
            Spacer()
            Text("\(ids.count) gewählt").font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }

    private func findingsMenu(_ ids: Set<Int>) -> NSMenu? {
        guard !ids.isEmpty else { return nil }
        let keys = model.keys(ids, store: store)
        let missing = model.missingKeys(ids, store: store)
        return CheckMenu.build([
            (String(localized: "Im Browser zeigen"), model.canReveal(ids), { model.reveal(ids) }),
            (String(localized: "Im Finder zeigen"), true, { model.showInFinder(ids) }),
            (String(localized: "Pfad kopieren"), true, { model.copyPaths(ids) }),
            nil,
            (String(localized: "Aus Collection entfernen …"), !keys.isEmpty, { model.askRemove(ids, store: store, trash: false) }),
            (String(localized: "Aus Collection entfernen + Dateien …"), !keys.isEmpty, { model.askRemove(ids, store: store, trash: true) }),
            (String(localized: "Analysieren"), !keys.isEmpty, { model.analyse(ids, store: store) }),
            (String(localized: "Fehlende → TIDAL"), !missing.isEmpty, { model.tidal(ids, store: store) }),
        ])
    }

    // MARK: Duplikate

    /// Zeilen je Gruppe: Behalter zuerst (grün … dann „entfällt“), Zeile -> Gruppe
    private func dupRows() -> (rows: [CheckRow], groupOf: [Int: Int]) {
        var rows: [CheckRow] = []
        var groupOf: [Int: Int] = [:]
        for (gi, item) in model.dups.enumerated() {
            for (mi, t) in ([item.plan.keeper] + item.plan.removed).enumerated() {
                let id = rows.count
                let keep = mi == 0
                rows.append(CheckRow(id: id, cells: [String(gi + 1), keep ? String(localized: "behalten") : String(localized: "entfällt"), model.short(t.path),
                                                     "\(t.bitrate)", t.analyzed ? "ja" : "–", "\(t.cues.count)",
                                                     t.rating > 0 ? String(repeating: "★", count: t.rating) : "", "\(t.playCount)",
                                                     t.fileExists ? String(localized: "lokal") : String(localized: "fehlt")],
                                     tint: keep ? NSColor(Theme.bone) : NSColor(Theme.muted)))
                groupOf[id] = gi
            }
        }
        return (rows, groupOf)
    }

    private var dupsPane: some View {
        let built = dupRows()
        let gi = dupSelection.sorted().first.flatMap { built.groupOf[$0] }
        let removedCount = model.dups.reduce(0) { $0 + $1.plan.removed.count }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                DeckButton(title: model.dupsReady ? "NEU BERECHNEN" : "DUPLIKATE SUCHEN") { model.computeDups(store: store) }
                    .disabled(store.tracks.isEmpty)
                DeckButton(title: "ZUSAMMENFÜHREN …", active: true, color: Theme.bone) { model.askMerge(store, trash: model.trashDups) }
                    .disabled(model.dups.isEmpty)
                DeckButton(title: "+ DATEIEN IN DEN PAPIERKORB", active: model.trashDups) { model.trashDups.toggle() }
                Spacer()
                Text(model.dupsReady ? String(localized: "\(model.dups.count) Gruppen · \(removedCount) Einträge entfallen")
                     : String(localized: "gleiche datei oder gleicher artist + titel, länge ±1 s, gleiche größe"))
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            if model.dupsReady, !model.dups.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    CheckTable(rows: built.rows,
                               columns: [CheckColumn(title: "#", width: 40, minWidth: 30), CheckColumn(title: "", width: 70, minWidth: 60),
                                         CheckColumn(title: "Pfad", width: 380, minWidth: 200), CheckColumn(title: "kbps", width: 50, minWidth: 40, muted: true),
                                         CheckColumn(title: String(localized: "Analyse"), width: 60, minWidth: 40, muted: true),
                                         CheckColumn(title: "Cues", width: 44, minWidth: 40, muted: true),
                                         CheckColumn(title: String(localized: "Bew."), width: 60, minWidth: 40, muted: true),
                                         CheckColumn(title: "Plays", width: 50, minWidth: 40, muted: true),
                                         CheckColumn(title: String(localized: "Datei"), width: 50, minWidth: 40, muted: true)],
                               selected: dupSelection, onSelect: { dupSelection = $0 }, onActivate: { _ in }, menu: { _ in nil })
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    dupPreview(gi)
                        .frame(width: 330)
                }
            } else {
                Spacer()
            }
        }
    }

    /// Vorschau der gewählten Gruppe: das Ergebnis im Behalter, bevor etwas geschrieben wird
    private func dupPreview(_ gi: Int?) -> some View {
        ScrollView {
            if let gi, model.dups.indices.contains(gi) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GRUPPE \(gi + 1) · \(model.dups[gi].reason)").font(Theme.label(11, .bold))
                    Text(model.preview(model.dups[gi].plan)).font(Theme.mono(10)).foregroundStyle(Theme.bone).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("zeile wählen: vorschau des ergebnisses").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    // MARK: Knöpfe

    private var footer: some View {
        HStack(spacing: 6) {
            if model.running {
                Text("abbrechen behält die befunde bis hierher").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                Spacer()
                DeckButton(title: "ABBRECHEN", active: true) { model.cancel() }
            } else {
                DeckButton(title: "NEU PRÜFEN") { model.start(store: store, musicFolders: musicFolders()) }
                    .disabled(store.tracks.isEmpty)
                Spacer()
                DeckButton(title: "BERICHT TXT …") { model.save(csv: false) }.disabled(!model.started)
                DeckButton(title: "BERICHT CSV …") { model.save(csv: true) }.disabled(!model.started)
                DeckButton(title: "SCHLIESSEN", active: true, color: Theme.bone) { NSApp.keyWindow?.performClose(nil) }
            }
        }
    }
}

/// Protokoll als Textfeld. Während des Laufs nur das Ende, das ins Feld passt (höchstens 10× je Sekunde neu
/// gezeichnet): ein mitlaufendes Dokument mit 2000 Zeilen kostete je Abruf 35–70 ms Hauptthread (Text neu zeichnen).
/// Danach alle gehaltenen Zeilen (bis 2000) zum Zurückscrollen.
struct LogTextView: NSViewRepresentable {
    let lines: [ConsistencyRun.LogLine]
    let tail: Bool
    let short: (String) -> String
    let shortText: (String) -> String

    final class Coordinator {
        var shownLast = -1
        var shownTail = false
        var drawn: CFTimeInterval = 0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private static let font = NSFont(name: "IBM Plex Mono", size: 10.5) ?? .monospacedSystemFont(ofSize: 10.5, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        sv.drawsBackground = true
        sv.backgroundColor = NSColor(Theme.chitin)
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(Theme.chitin)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.layoutManager?.allowsNonContiguousLayout = true
        // feste Breite, eine Zeile je Datei (lange Pfade in der Mitte gekürzt): Breite ändert sich nie -> kein Neuaufbau
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let c = context.coordinator
        let last = lines.last?.id ?? 0
        guard last != c.shownLast || tail != c.shownTail else { return }
        let now = CACurrentMediaTime()
        if tail, c.shownTail, now - c.drawn < 0.1 { return }   // nächster Abruf zeichnet
        let shown: ArraySlice<ConsistencyRun.LogLine>
        if tail {
            let lineHeight = max(1, NSLayoutManager().defaultLineHeight(for: Self.font))
            shown = lines.suffix(max(5, Int(sv.contentView.bounds.height / lineHeight)))
        } else {
            shown = lines[...]
        }
        storage.setAttributedString(render(shown))
        tv.scrollToEndOfDocument(nil)
        c.shownLast = last; c.shownTail = tail; c.drawn = now
    }

    private func render(_ list: ArraySlice<ConsistencyRun.LogLine>) -> NSAttributedString {
        let font = Self.font
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        // Pfad-Spalte über einen Tabstopp: Leerzeichen-Breiten verschoben die Spalte je nach Zeile
        para.tabStops = [NSTextTab(textAlignment: .left, location: ceil(("MISS  " as NSString).size(withAttributes: [.font: font]).width))]
        let bone = NSColor(Theme.bone), muted = NSColor(Theme.muted)
        let red = NSColor(Theme.state), lila = NSColor(Theme.secondary)
        let out = NSMutableAttributedString()
        for (i, l) in list.enumerated() {
            let start = out.length
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            defer { out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: start, length: out.length - start)) }
            out.append(NSAttributedString(string: (l.category?.tag ?? "OK").trimmingCharacters(in: .whitespaces),
                                          attributes: [.font: font, .foregroundColor: l.category.map { $0.isProblem ? red : lila } ?? muted]))
            out.append(NSAttributedString(string: "\t" + short(l.path), attributes: [.font: font, .foregroundColor: l.category == nil ? muted : bone]))
            if !l.detail.isEmpty {
                out.append(NSAttributedString(string: "  · " + shortText(l.detail), attributes: [.font: font, .foregroundColor: muted]))
            }
        }
        return out
    }
}

/// Selbsttest ohne Fenster (MIX741_SELFTEST=1 MIX741_CHECK=1): echte Collection nur lesen, prüfen, Zähler je
/// Kategorie und Dauer ausgeben. MIX741_CHECK_LIST=<n>: je Kategorie die ersten n Befunde.
@MainActor
enum ConsistencyCLI {
    nonisolated static var requested: Bool { Session.isSelfTest && ProcessInfo.processInfo.environment["MIX741_CHECK"] == "1" }

    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        let url = env["MIX741_CHECK_NML"].map { URL(fileURLWithPath: $0) } ?? LibraryStore.defaultNML
        func log(_ s: String) { print("[check] \(s)"); fflush(stdout) }
        guard let input = input(url: url) else { log("collection nicht lesbar: \(url.path)"); exit(1) }
        log("\(url.path) · \(input.tracks.count) tracks · \(input.lists.count) playlists · musik-ordner \(input.musicRoots)")
        let run = ConsistencyRun.start(input)
        while true {
            let s = run.snapshot(sinceLine: .max, sinceFinding: .max)
            if s.finished { break }
            log(String(format: "%@ %d / %d · %.1f s", s.phase.rawValue, s.done, s.total, s.elapsed))
            Thread.sleep(forTimeInterval: 2)
        }
        run.wait()
        let s = run.snapshot(sinceLine: .max, sinceFinding: .max)
        let f = run.allFindings
        log(String(format: "fertig in %.1f s · %d / %d tracks geprüft · %d ok · %d dateien in musik-ordnern",
                   s.elapsed, s.done, s.total, s.ok, s.folderFiles))
        let n = Int(env["MIX741_CHECK_LIST"] ?? "") ?? 0
        for c in Check.Category.allCases {
            log("\(c.tag) \(String(format: "%6d", s.counts[c] ?? 0))  \(c.rawValue)")
            for x in f.filter({ $0.category == c }).prefix(n) { log("       \(x.path) · \(x.detail)") }
        }
        exit(0)
    }

    /// Prüf-Eingabe aus der Collection-Datei (nur lesen) wie in der App: Playlists, Musik-Ordner aus den Einstellungen
    nonisolated static func input(url: URL) -> Check.Input? {
        guard let c = try? NMLParser.parse(url: url) else { return nil }
        let configured = AppPrefs.load().ui.musicFolders
        let roots = !configured.isEmpty ? configured
            : MusicFolder.defaultRoot(paths: c.tracks.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }).map { [$0] } ?? []
        let ui = AppPrefs.load().ui
        return Check.Input(tracks: c.tracks, lists: Check.lists(in: c.root), musicRoots: ui.checkMusicFolders ? roots : [])
    }
}

/// Bild offscreen (MIX741_SELFTEST=1 MIX741_SHOT=consistency:<png>): echter Prüflauf über die Collection (nur lesen),
/// <name>-running.png bei ~40 %, <name>-done.png nach dem Ende (Befunde). Kein sichtbares Fenster, kein Audio.
@MainActor
enum ConsistencyShot {
    static func run(_ spec: String) -> Never {
        let base = URL(fileURLWithPath: String(spec.dropFirst("consistency:".count))).deletingPathExtension()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = LibraryStore()
        store.folders.configured = AppPrefs.load().ui.musicFolders
        store.load()
        func spin(_ s: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        spin(120) { !store.tracks.isEmpty }
        let model = ConsistencyModel()
        let view = ConsistencyView(model: model, musicFolders: { true }).environment(store)
        let host = NSHostingView(rootView: view)
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 720)
        let win = NSWindow(contentRect: rect.offsetBy(dx: -20000, dy: -20000), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.frame = rect
        // längste Lücke des Hauptthreads während des Laufs (20-Hz-Abruf + Protokoll-Darstellung)
        var last = CACurrentMediaTime(), worst = 0.0
        let tick = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let now = CACurrentMediaTime(); worst = max(worst, now - last)
            if now - last > 0.03 { print(String(format: "[hitch] %.0f ms bei %d / %d", (now - last) * 1000, model.snap.done, model.snap.total)) }
            last = now
        }
        RunLoop.main.add(tick, forMode: .common)
        model.start(store: store, musicFolders: AppPrefs.load().ui.checkMusicFolders)
        func shot(_ name: String) {
            spin(0.3)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("[shot] \(url.path)")
        }
        spin(600) { model.fraction >= 0.4 || model.snap.finished }
        let runGap = worst
        shot("running")
        worst = 0
        spin(900) { model.snap.finished }
        print(String(format: "[shot] fertig in %.1f s · %d befunde · längste lücke hauptthread %.0f ms (bis 40 %%), %.0f ms (danach)",
                     model.snap.elapsed, model.findings.count, runGap * 1000, worst * 1000))
        shot("done")
        exit(0)
    }
}
