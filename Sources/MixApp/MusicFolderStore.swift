import SwiftUI
import AppKit
import MixCore

/// MUSIC FOLDERS: Musik-Ordner als Dateibaum. Ordner werden erst beim Aufklappen/Anzeigen im Hintergrund gelesen
/// und zwischengespeichert; Dateien aus der Collection zeigen deren Metadaten, alle anderen kommen als lose Tracks.
@MainActor @Observable
final class MusicFolderStore {
    /// eingestellte Ordner (⌘, → browser → collection); leer = Standard aus der Collection
    var configured: [String] = []
    /// tiefster Ordner mit 90 % der vorhandenen Collection-Dateien, beim Laden der Collection berechnet
    private(set) var defaultRoot: String?
    /// gelesene Ordner (eine Ebene): Unterordner + Audiodateien
    private(set) var listings: [String: MusicFolder.Listing] = [:]
    /// zählt jede neu gelesene Liste (Browser-Zwischenspeicher)
    private(set) var revision = 0

    /// rekursiv gelesene Ordner (Schalter UNTERORDNER)
    @ObservationIgnored private var deep: [String: MusicFolder.Listing] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    /// Stand je Ordner (f:/r: + Pfad) – der Browser sortiert nur neu, wenn sich sein eigener Ordner ändert
    @ObservationIgnored private var stamps: [String: Int] = [:]
    /// Pfad der Collection-Datei (Vergleichsform) → Track-Schlüssel, einmal je geladener Collection
    @ObservationIgnored private var index: [String: String] = [:]
    /// Dateien außerhalb der Collection, die schon angezeigt wurden (Laden, Vorhören, Controller)
    @ObservationIgnored private(set) var loose: [String: Track] = [:]
    @ObservationIgnored private var cache: [String: (stamp: [Int], tracks: [Track])] = [:]
    @ObservationIgnored private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var watchOrder: [String] = []
    @ObservationIgnored private var rescanPending: Set<String> = []
    /// höchstens 4 Ordner gleichzeitig lesen (Google Drive, Netzlaufwerke)
    @ObservationIgnored private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    var roots: [String] {
        if !configured.isEmpty { return configured }
        return defaultRoot.map { [$0] } ?? []
    }

    /// nach dem Laden der Collection (Index und Standard-Ordner im Hintergrund berechnet)
    func collectionLoaded(index: [String: String], defaultRoot: String?) {
        self.index = index
        self.defaultRoot = defaultRoot ?? (E2E.music ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")).path
        cache = [:]
        revision += 1
        loads += 1
    }
    @ObservationIgnored private var loads = 0

    /// Änderungsstand eines Ordners für den Browser-Zwischenspeicher (liest `revision` → beobachtet)
    func stamp(_ path: String, recursive: Bool) -> Int {
        _ = revision
        return loads &* 1_000_003 &+ (stamps[(recursive ? "r:" : "f:") + path] ?? 0)
    }

    /// Unterordner (nil = noch nicht gelesen, wird angestoßen)
    func subfolders(_ path: String) -> [String]? {
        guard let l = listings[path] else { request(path, recursive: false); return nil }
        return l.folders
    }

    /// Dateien eines Ordners als Tracks: aus der Collection (mit Metadaten) oder lose (grau, ohne Grid)
    func tracks(in path: String, recursive: Bool, library: LibraryStore) -> [Track] {
        guard let l = recursive ? deep[path] : listings[path] else { request(path, recursive: recursive); return [] }
        watch(path)
        let k = (recursive ? "r:" : "f:") + path
        let stamp = [stamp(path, recursive: recursive), library.revision]
        if let c = cache[k], c.stamp == stamp { return c.tracks }
        var out: [Track] = []
        out.reserveCapacity(l.files.count)
        for f in l.files {
            if let key = index[f.match], let t = library.byKey[key] {
                out.append(t)
            } else if let t = library.cutStore.byMatch[f.match] {
                out.append(t)   // geschnittene Datei: Metadaten aus CUTS
            } else {
                // lose Datei: eigene Analyse darüber (Tempo, Grid, Tonart, Lautheit)
                let t = library.analysis.entry(for: f.loose.key).map { $0.apply(to: f.loose) } ?? f.loose
                loose[t.key] = t
                out.append(t)
            }
        }
        cache[k] = (stamp, out)
        return out
    }

    /// neue Analyse einer losen Datei übernehmen; die Listen bauen sich beim nächsten Lesen neu
    func applyAnalysis(_ a: TrackAnalysis, to key: String) {
        guard let t = loose[key] else { return }
        loose[key] = a.apply(to: t)
        invalidate()
    }

    /// Analyse einer losen Datei verworfen: beim nächsten Lesen wieder ohne Werte
    func forget(_ key: String) {
        loose[key] = nil
        invalidate()
    }

    private func invalidate() {
        cache = [:]
        loads += 1
        revision += 1
    }

    /// neue Datei (Schneiden): schon gelesene Ordner, die sie enthalten, neu einlesen (Cloud-Ordner melden das nicht immer)
    func fileAdded(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        cache = [:]
        if listings[dir] != nil { request(dir, recursive: false, force: true) }
        for p in deep.keys where dir == p || dir.hasPrefix(p.hasSuffix("/") ? p : p + "/") { request(p, recursive: true, force: true) }
        revision += 1
    }

    /// Ordner (und darunter gelesene) neu einlesen – Rechtsklick „Neu einlesen“ oder Änderung im Dateisystem
    func rescan(_ path: String) {
        let inside = { (p: String) in p == path || p.hasPrefix(path.hasSuffix("/") ? path : path + "/") }
        for p in listings.keys where inside(p) { request(p, recursive: false, force: true) }
        for p in deep.keys where inside(p) { request(p, recursive: true, force: true) }
        if listings[path] == nil { request(path, recursive: false, force: true) }
    }

    private func request(_ path: String, recursive: Bool, force: Bool = false) {
        let k = (recursive ? "r:" : "f:") + path
        guard force || !pending.contains(k) else { return }
        pending.insert(k)
        queue.addOperation { [weak self] in
            let l = MusicFolder.list(path, recursive: recursive)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.publish(path, recursive: recursive, l) }
            }
        }
    }

    private func publish(_ path: String, recursive: Bool, _ l: MusicFolder.Listing) {
        pending.remove((recursive ? "r:" : "f:") + path)
        if recursive { deep[path] = l } else { listings[path] = l }
        stamps[(recursive ? "r:" : "f:") + path, default: 0] += 1
        revision += 1
    }

    /// angezeigte Ordner beobachten (höchstens 16): neue/gelöschte Dateien → neu einlesen (0,5 s gebündelt)
    private func watch(_ path: String) {
        if watchers[path] != nil { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rescanPending.insert(path).inserted else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        self.rescanPending.remove(path)
                        self.rescan(path)
                    }
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers[path] = src
        watchOrder.append(path)
        if watchOrder.count > 16 { watchers.removeValue(forKey: watchOrder.removeFirst())?.cancel() }
    }
}

/// Baum-Knoten MUSIC FOLDERS: eingestellte Ordner, Unterordner klappen auf und werden erst dann gelesen
struct MusicFolderTree: View {
    @Environment(LibraryStore.self) private var store
    @Binding var selection: BrowserSource
    @State private var open = false
    @State private var expanded: Set<String> = []

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(store.folders.roots, id: \.self) { p in
                MusicFolderRow(path: p, expanded: $expanded)
            }
        } label: {
            MusicFolderRow.label("▸", "MUSIC FOLDERS")
        }
        .onAppear { expandToSelection() }
        .onChange(of: selection) { expandToSelection() }
        .onChange(of: store.folders.roots) { expandToSelection() }
    }

    /// gewählten Ordner sichtbar machen (z. B. nach dem Wiederherstellen der Sitzung)
    private func expandToSelection() {
        guard case let .folder(p) = selection,
              let root = store.folders.roots.first(where: { p == $0 || p.hasPrefix($0 + "/") }) else { return }
        open = true
        var dir = (p as NSString).deletingLastPathComponent
        while dir.count >= root.count, dir.hasPrefix(root) {
            expanded.insert(dir)
            if dir == root { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
}

struct MusicFolderRow: View, SourceMenus {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) var store
    @Environment(HistoryStore.self) var history
    @Environment(PlaylistTreeUI.self) private var ui
    let path: String
    @Binding var expanded: Set<String>

    var body: some View {
        let subs = store.folders.subfolders(path)
        if let subs, !subs.isEmpty {
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(path) },
                                                set: { if $0 { expanded.insert(path) } else { expanded.remove(path) } })) {
                if expanded.contains(path) {
                    ForEach(subs, id: \.self) { MusicFolderRow(path: $0, expanded: $expanded) }
                }
            } label: { folderLabel }
        } else {
            folderLabel
        }
    }

    private var folderLabel: some View {
        Self.label("▱", (path as NSString).lastPathComponent)
            .help(path)
            .tag(BrowserSource.folder(path))
            .favoriteDrag { [path] in BrowserFavorite.source(.folder(path), store: store) }
            .contextMenu {
                Button("Neu einlesen") { store.folders.rescan(path) }
                resetPlayedButton(.folder(path), marked: ui.marked)
                autoMixMenuButton(.folder(path), marked: ui.marked, mix: mix)
                OverviewMenuButton { store.folders.tracks(in: path, recursive: true, library: store) }
                AnalysisMenuButtons { store.folders.tracks(in: path, recursive: true, library: store) }
                ImportMenuButton(source: (path as NSString).lastPathComponent) { store.folders.tracks(in: path, recursive: true, library: store) }
                FolderToPlaylistMenu(path: path)
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Pfad kopieren") { TrackMenu.copy(path) }
            }
    }

    static func label(_ glyph: String, _ name: String) -> some View {
        HStack(spacing: 6.z) {
            Text(glyph).font(Theme.mono(11.z)).foregroundStyle(Theme.muted).frame(width: 12.z)
            Text(name).font(Theme.mono(11.z)).foregroundStyle(Theme.bone).lineLimit(1)
        }
        .frame(minHeight: 20.z)
    }
}

/// Einstellungen → Browser → Collection: Musik-Ordner hinzufügen/entfernen
struct MusicFolderSettings: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let list = mix.prefs.ui.musicFolders
        LabeledContent("Musik-Ordner (MUSIC FOLDERS)") {
            Button("Ordner hinzufügen …") { add() }
        }
        .settingsAnchor("browser.musicfolders")
        if list.isEmpty {
            Text("automatisch: \(store.folders.defaultRoot ?? "—")")
                .font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.middle)
        }
        ForEach(list, id: \.self) { p in
            HStack {
                Text(verbatim: p).font(Theme.mono(10)).lineLimit(1).truncationMode(.middle).help(p)
                Spacer()
                Button("Entfernen") { mix.prefs.ui.musicFolders.removeAll { $0 == p } }
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let d = store.folders.roots.first { panel.directoryURL = URL(fileURLWithPath: d) }
        guard panel.runModal() == .OK else { return }
        var list = mix.prefs.ui.musicFolders
        // erster eigener Ordner: der automatische bleibt dabei
        if list.isEmpty, let d = store.folders.defaultRoot { list = [d] }
        for u in panel.urls where !list.contains(u.path) { list.append(u.path) }
        mix.prefs.ui.musicFolders = list
    }
}

/// Selbsttest-Bild (MIX741_SELFTEST=1 MIX741_SHOT=browser:<png>): Baum mit aufgeklapptem MUSIC FOLDERS und die
/// Dateiliste eines Unterordners (MIX741_SHOT_FOLDER, sonst der erste), darüber die Favoritenleiste; dazu
/// `<png>-fav-narrow/-click/-empty.png` (schmal, Klick in den Baum + Filter, leer). Offscreen gerendert – kein Fenster
/// auf dem Bildschirm, kein Audio, keine Controller, keine Einstellungen geschrieben
@MainActor
enum BrowserShot {
    static func run(_ spec: String) -> Never {
        guard spec.hasPrefix("browser:") else { print("[shot] unbekannt: \(spec)"); exit(2) }
        let out = URL(fileURLWithPath: String(spec.dropFirst(8)))
        let store = LibraryStore()
        let history = HistoryStore()
        store.folders.configured = AppPrefs.load().ui.musicFolders
        store.load()
        func spin(_ s: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        spin(120) { !store.tracks.isEmpty }
        guard let root = store.folders.roots.first else { print("[shot] kein Musik-Ordner"); exit(1) }
        print("[shot] collection \(store.tracks.count) tracks · standard-ordner \(store.folders.defaultRoot ?? "-") · ordner \(store.folders.roots)")
        spin(30) { store.folders.subfolders(root) != nil }
        let env = ProcessInfo.processInfo.environment["MIX741_SHOT_FOLDER"]
        let folder = env ?? store.folders.subfolders(root)?.first ?? root
        let t0 = Date()
        spin(60) { store.folders.subfolders(folder) != nil }
        let scan = Date().timeIntervalSince(t0)
        let t1 = Date()
        let tracks = store.folders.tracks(in: folder, recursive: false, library: store)
        let map = Date().timeIntervalSince(t1)
        let inColl = tracks.filter { !$0.loose }.count
        print(String(format: "[shot] %@: %d dateien (%d in der collection, %d lose), lesen %.0f ms, zuordnen %.1f ms",
                     folder, tracks.count, inColl, tracks.count - inColl, scan * 1000, map * 1000))
        _ = store.folders.tracks(in: root, recursive: true, library: store)
        let t2 = Date()
        spin(120) { !store.folders.tracks(in: root, recursive: true, library: store).isEmpty }
        let all = store.folders.tracks(in: root, recursive: true, library: store)
        print(String(format: "[shot] unterordner %@: %d dateien (%d in der collection), lesen %.2f s",
                     root, all.count, all.filter { !$0.loose }.count, Date().timeIntervalSince(t2)))

        // Favoritenleiste: belegt (Ordner aktiv, Playlist, Smartlist, Filter, fehlendes Ziel), leer, schmal
        let pane = BrowserPaneModel(name: "Shot", source: .folder(folder))
        let browser = BrowserState()
        browser.store = store
        func nodes(_ n: PlaylistNode) -> [PlaylistNode] { (n.kind == .folder ? [] : [n]) + n.children.flatMap(nodes) }
        let lists = nodes(store.root)
        var favs: [BrowserFavorite?] = [BrowserFavorite.source(.collection, store: store),
                                        BrowserFavorite.source(.folder(folder), store: store),
                                        lists.first { $0.kind == .playlist }.flatMap { BrowserFavorite.source(.node($0), store: store) },
                                        lists.first { $0.kind == .smartlist }.flatMap { BrowserFavorite.source(.node($0), store: store) },
                                        BrowserFavorite.filter(tags: ["B sub"], roles: ["BASIS"], search: ""),
                                        BrowserFavorite(.node, name: "Gelöschte Playlist", id: "0", path: ["—"], node: "playlist")]
        if let f = favs[2] { favs[2]?.name = String(f.name.prefix(10)) }
        pane.favorites = favs
        for (i, f) in favs.enumerated() {
            let t = f.map { String(describing: $0.target(store: store)).prefix(60) } ?? "leer"
            print("[shot] favorit \(i + 1): \(f?.name ?? "—") -> \(t)")
        }
        let shotList = ShotList(tracks: Array(tracks.sorted { ($0.loose ? 1 : 0, $0.artist) < ($1.loose ? 1 : 0, $1.artist) }.prefix(40)))

        func render(_ to: URL, width: CGFloat, height: CGFloat = 720, clickTree: Bool = false) {
            let view = VStack(spacing: 0) {
                FavoritesBar(model: pane)
                HStack(spacing: 0) {
                    SourceTree(selection: Binding(get: { pane.source }, set: { pane.source = $0 })).frame(width: min(300, width * 0.4))
                    shotList.frame(minWidth: 0, maxWidth: .infinity).clipped()
                }
            }
            .frame(width: width, height: height)
            .background(Theme.background)
            .environment(store)
            .environment(history)
            .environment(browser)
            .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            spin(3)   // Unterordner der sichtbaren Knoten einlesen lassen
            host.layoutSubtreeIfNeeded()
            if clickTree { treeClick(host, win, pane, store) }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: to)
            print("[shot] \(to.path)")
        }
        let base = out.deletingPathExtension().path
        render(out, width: 1100)
        render(URL(fileURLWithPath: base + "-fav-narrow.png"), width: 620, height: 260)
        // Klick in den Baum wählt trotz ziehbarer Einträge aus; Filter-Favorit aktiv
        render(URL(fileURLWithPath: base + "-fav-click.png"), width: 1100, height: 260, clickTree: true)
        pane.favorites = BrowserFavorite.normalized(nil)
        render(URL(fileURLWithPath: base + "-fav-empty.png"), width: 1100, height: 260)
        exit(0)
    }

    /// Klick auf TRACK COLLECTION (Maus runter/hoch an die Baumliste) -> Quelle des Bereichs; danach Filter-Favorit
    private static func treeClick(_ host: NSView, _ win: NSWindow, _ pane: BrowserPaneModel, _ store: LibraryStore) {
        var stack: [NSView] = [host], outline: NSOutlineView?
        while let v = stack.popLast() { if let o = v as? NSOutlineView { outline = o; break }; stack += v.subviews }
        guard let o = outline, o.numberOfRows > 0 else { print("[shot] baum: keine liste"); return }
        let before = pane.source
        let p = o.convert(NSPoint(x: o.rect(ofRow: 0).midX, y: o.rect(ofRow: 0).midY), to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // wie das Fenster: tiefste Ansicht unter dem Klick bekommt mouseDown (ohne Aktivieren der App)
        if let up = ev(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        if let down = ev(.leftMouseDown), let hit = win.contentView?.hitTest(win.contentView!.convert(p, from: nil)) {
            print("[shot] baum-klick trifft \(type(of: hit))")
            hit.mouseDown(with: down)
        }
        let end = Date().addingTimeInterval(1)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        print("[shot] baum-klick: \(before.title) -> \(pane.source.title) \(pane.source == .collection ? "ok" : "FEHLER")")
        // Ziehen: die Liste liefert für jede Zeile einen Favoriten (Ablegen selbst braucht eine echte Maus)
        for row in [0, o.numberOfRows - 1] {
            let w = o.dataSource?.outlineView?(o, pasteboardWriterForItem: o.item(atRow: row) as Any)
            let f = FavoriteDrag.take()
            print("[shot] ziehen zeile \(row): \(w == nil ? "-" : "pasteboard") · favorit \(f.map { "\($0.type) \($0.name) \($0.path ?? [])" } ?? "-")")
        }
        pane.applyFavorite(4, store: store)
        host.layoutSubtreeIfNeeded()
    }

    /// vereinfachte Tabelle (die echte TrackTable braucht das Audio-Modell)
    private struct ShotList: View {
        let tracks: [Track]
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(tracks) { t in
                    HStack(spacing: 8) {
                        Text(t.artist).frame(width: 200, alignment: .leading)
                        Text(t.title).frame(width: 260, alignment: .leading)
                        Text(t.bpm > 0 ? String(format: "%.2f", t.bpm) : "").frame(width: 60, alignment: .trailing)
                        Text(t.openKey).frame(width: 36)
                        Text(t.comment2).frame(width: 200, alignment: .leading)
                    }
                    .lineLimit(1)
                    .foregroundStyle(t.loose ? Theme.muted : Theme.bone)
                }
                Spacer()
            }
            .font(Theme.mono(11))
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.void)
        }
    }
}

/// EXPLORER: Laufwerke (USB-Sticks, externe Platten, Netz) und Benutzerordner wie im Finder. Ordner wie bei
/// MUSIC FOLDERS (Unterordner aufklappen, Audiodateien in der Liste). Laufwerke folgen dem Ein-/Ausstecken
struct ExplorerTree: View {
    @Binding var selection: BrowserSource
    @State private var open = false
    @State private var expanded: Set<String> = []
    @State private var volumes: [URL] = ExplorerTree.mountedVolumes()
    @State private var placesRevision = 0
    @State private var text = ""
    @State private var search = ExplorerSearch()

    static func mountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeNameKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.volumeIsRootFileSystemKey]).volumeIsRootFileSystem) != true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Startordner des Explorers. Ob es sie gibt, steht im Zwischenspeicher (Prüfung im Hintergrund, siehe `body`);
    /// unbekannt = anzeigen. `revision` nur, damit die Ansicht nach der Prüfung neu gebaut wird
    static func places(_ revision: Int) -> [String] {
        _ = revision
        return placePaths.filter { FileStatCache.shared.cached($0) ?? true }
    }
    static var placePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.path] + ["Music", "Desktop", "Downloads"].map { home.appendingPathComponent($0).path }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            TextField("Suchen (Ordner, Dateien)", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.mono(11.z))
                .onChange(of: text) { search.run(text) }
            if !text.isEmpty {
                // Treffer: Ordner wie oben aufklappbar, Klick zeigt die Dateien in der Liste
                ForEach(search.folders, id: \.self) { MusicFolderRow(path: $0, expanded: $expanded) }
                if search.folders.isEmpty {
                    Text(search.running ? "sucht …" : "nichts gefunden").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
                }
            } else {
                ForEach(volumes, id: \.self) { v in
                    MusicFolderRow(path: v.path, expanded: $expanded)
                        .contextMenu {
                            Button("Auswerfen") { try? NSWorkspace.shared.unmountAndEjectDevice(at: v) }
                            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([v]) }
                        }
                }
                ForEach(Self.places(placesRevision), id: \.self) { MusicFolderRow(path: $0, expanded: $expanded) }
            }
        } label: {
            MusicFolderRow.label("⌂", "EXPLORER")
        }
        .onAppear { FileStatCache.shared.refresh(Self.placePaths) { placesRevision += 1 } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in volumes = Self.mountedVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in volumes = Self.mountedVolumes() }
    }
}

/// Rechtsklick auf einen Ordner: alle Audiodateien samt Unterordnern in eine eigene Playlist (neu oder vorhandene)
struct FolderToPlaylistMenu: View {
    @Environment(LibraryStore.self) private var store
    let path: String

    var body: some View {
        Menu("Alle Tracks mit Unterordnern in Playlist") {
            Button("Neue Playlist „\((path as NSString).lastPathComponent)“") {
                guard let keys = keys() else { return }
                let it = store.addOwn(.playlist, into: nil, name: (path as NSString).lastPathComponent, tracks: keys)
                StatusCenter.post(.ok, String(localized: "\(it.tracks.count) Tracks in „\(it.name)“"), key: "playlist")
            }
            let lists = Self.playlists(store.playlists.items)
            if !lists.isEmpty { Divider() }
            ForEach(lists, id: \.id) { it in
                Button(it.name) { if let keys = keys() { store.addToPlaylist(keys, it.id) } }
            }
        }
    }

    /// Tracks des Ordners samt Unterordnern; noch nicht gelesen -> Hinweis, Lesen läuft
    private func keys() -> [String]? {
        let t = store.folders.tracks(in: path, recursive: true, library: store)
        guard !t.isEmpty else {
            StatusCenter.post(.info, String(localized: "Ordner wird gelesen – gleich noch einmal versuchen"), key: "playlist")
            return nil
        }
        return t.map(\.key)
    }

    /// eigene Playlists (ohne Ordner und Smartlists), mit Ordnerpfad im Namen
    static func playlists(_ items: [PlaylistItem], prefix: String = "") -> [(id: UUID, name: String)] {
        items.flatMap { it -> [(id: UUID, name: String)] in
            switch it.kind {
            case .folder: return playlists(it.children, prefix: prefix + it.name + " / ")
            case .playlist: return [(it.id, prefix + it.name)]
            case .smartlist: return []
            }
        }
    }
}
