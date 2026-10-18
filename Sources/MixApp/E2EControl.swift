import AppKit
import Foundation
import MixCore
import MixEngine

/// Steuerung für Ende-zu-Ende-Tests (nur mit `MIX741_E2E_ROOT`, Tests/E2E/README.md). Ordnerpost wie PairDebug:
/// Anfrage `<root>/control/outbox/<token>.json` (`{"command", "args", "token"}`), Antwort `<root>/control/inbox/<token>.json`
/// (`{"ok", "command", "token", "body", "at"}`). Befehle laufen über dieselben Wege wie die Oberfläche; wartende Befehle
/// (`wait-ready`, `analyze`) antworten, sobald die Bedingung gilt oder die Frist um ist. Abfrage alle 0,1 s.
@MainActor
final class E2EControl {
    private static var instance: E2EControl?

    private let mix: MixModel
    private let store: LibraryStore
    private let browser: BrowserState
    private let history: HistoryStore
    private var timer: Timer?
    private let started = Date()

    /// eine Anfrage, die auf eine Bedingung wartet; `check` liefert den Antwortkörper, sobald sie gilt
    private struct Waiting {
        let token: String?, command: String, deadline: Date
        let check: () -> Any?
        let timeoutBody: String
    }
    private var waiting: [Waiting] = []

    /// Start im Hauptfenster (startControllers); nur mit `MIX741_E2E_ROOT`
    static func start(mix: MixModel, store: LibraryStore, browser: BrowserState, history: HistoryStore) {
        guard E2E.isActive, instance == nil, let dir = E2E.control else { return }
        setvbuf(stdout, nil, _IOLBF, 0)   // Ausgabe in die Log-Datei sofort (Ende-zu-Ende)
        let c = E2EControl(mix: mix, store: store, browser: browser, history: history)
        instance = c
        for sub in ["outbox", "inbox"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        c.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { instance?.tick() } }
        print("[e2e] Steuerung bereit: \(dir.path) · Instanz \(E2E.name)")
    }

    private init(mix: MixModel, store: LibraryStore, browser: BrowserState, history: HistoryStore) {
        self.mix = mix
        self.store = store
        self.browser = browser
        self.history = history
    }

    private var outbox: URL { E2E.control!.appendingPathComponent("outbox", isDirectory: true) }
    private var inbox: URL { E2E.control!.appendingPathComponent("inbox", isDirectory: true) }

    private func tick() {
        let now = Date()
        for w in waiting {
            if let body = w.check() {
                reply(token: w.token, command: w.command, ok: true, body: body)
            } else if now > w.deadline {
                reply(token: w.token, command: w.command, ok: false, body: ["fehler": w.timeoutBody])
            } else {
                continue
            }
            waiting.removeAll { $0.token == w.token && $0.command == w.command && $0.deadline == w.deadline }
        }
        let names = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
        for url in names.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            guard let data, let req = PairDebugFile.request(data) else { continue }
            dispatch(req)
        }
    }

    // MARK: Befehle

    private func dispatch(_ req: PairDebugFile.Request) {
        let a = object(req.args)
        let token = req.token
        func done(_ ok: Bool, _ body: Any) { reply(token: token, command: req.command, ok: ok, body: body) }
        func wait(_ timeout: Double, _ timeoutText: String, _ check: @escaping () -> Any?) {
            waiting.append(Waiting(token: token, command: req.command, deadline: Date().addingTimeInterval(timeout),
                                   check: check, timeoutBody: timeoutText))
        }
        let pane = browser.pane(a["pane"] as? Int ?? 0)
        switch req.command {
        case "ping":
            done(true, ["name": E2E.name, "root": E2E.root?.path ?? "", "build": bundleValue("CFBundleVersion"),
                        "pid": ProcessInfo.processInfo.processIdentifier, "uptime": Date().timeIntervalSince(started)])

        case "wait-ready":
            wait(a["timeout"] as? Double ?? 60, "Collection nicht geladen") { [store] in
                store.tracks.isEmpty || store.sourceURL == nil ? nil : ["tracks": store.tracks.count]
            }

        case "snapshot":
            done(true, snapshot())

        case "select-source":
            let id = a["source"] as? String ?? ""
            guard let src = source(id) else { return done(false, "unbekannte Quelle: \(id)") }
            pane.source = src
            done(true, ["pane": (a["pane"] as? Int) ?? 0, "source": Session.sourceID(src) ?? id])

        case "search":
            pane.search = a["text"] as? String ?? ""
            done(true, ["pane": (a["pane"] as? Int) ?? 0, "search": pane.search])

        case "list":
            let rows = visibleRows(pane)
            done(true, ["count": rows.count, "rows": rows.enumerated().map { i, t in row(t, index: i) }])

        case "load":
            let rows = visibleRows(pane)
            let d = a["deck"] as? Int ?? 0
            let t: Track? = (a["key"] as? String).flatMap { store.track($0) }
                ?? (a["index"] as? Int).flatMap { $0 < rows.count ? rows[$0] : nil }
            guard let t, d >= 0, d < MixEngine.deckCount else { return done(false, "Track oder Deck fehlt") }
            let accepted = mix.load(t, deck: d, force: a["force"] as? Bool)
            done(accepted, ["deck": d, "key": t.key, "accepted": accepted])

        case "play", "pause":
            let d = a["deck"] as? Int ?? 0
            guard d >= 0, d < MixEngine.deckCount else { return done(false, "Deck fehlt") }
            if mix.deck(d).playing != (req.command == "play") { mix.togglePlay(d) }
            done(true, ["deck": d, "playing": mix.deck(d).playing])

        case "sync":
            let d = a["deck"] as? Int ?? 0
            let on = a["on"] as? Bool ?? true
            guard d >= 0, d < MixEngine.deckCount else { return done(false, "Deck fehlt") }
            if mix.deck(d).sync != on { mix.toggleSync(d) }
            done(true, ["deck": d, "sync": mix.deck(d).sync])

        case "master":
            let d = a["deck"] as? Int ?? 0
            guard d >= 0, d < MixEngine.deckCount else { return done(false, "Deck fehlt") }
            if mix.core.snapshot().effectiveMaster != d { mix.toggleMaster(d) }
            done(true, ["deck": d, "master": mix.core.snapshot().effectiveMaster ?? -1])

        case "set-prefs":
            let r = PairDebugResponder.answer(command: "prefs-set", args: req.args, mix: mix, allowed: true)
            done(r.ok, parsedBody(r.body))

        case "ui-stats":
            // Lücken des Hauptthreads (MainStall); "reset": true liefert den Stand seit dem letzten Zurücksetzen und zählt dann neu
            let s = a["reset"] as? Bool == true ? MainStall.takeStats() : MainStall.stats
            done(true, ["ticks": s.ticks, "over16": s.over16, "over50": s.over50, "maxMs": (s.maxMs * 10).rounded() / 10,
                        "pulls": s.pulls, "changes": s.changes, "pid": ProcessInfo.processInfo.processIdentifier])

        case "link":
            // Link ein/aus (wie LINK-Taste); "on" fehlt = umschalten
            let on = a["on"] as? Bool
            if let on { mix.setLink(on) } else { mix.toggleLink() }
            done(true, ["linkEnabled": mix.state.linkEnabled])

        case "prefs-get", "status":
            let r = PairDebugResponder.answer(command: req.command, args: "", mix: mix, allowed: true)
            done(r.ok, parsedBody(r.body))

        case "analyze":
            let keys = a["keys"] as? [String] ?? []
            let tracks = keys.compactMap { store.track($0) }
            guard tracks.count == keys.count, !keys.isEmpty else { return done(false, "unbekannte Track-Schlüssel") }
            Analyses.shared.enqueue(tracks, refresh: true)
            wait(a["timeout"] as? Double ?? 180, "Analyse nicht fertig") { [self] in
                let pending = keys.contains { key in
                    store.analysis.entry(for: key) == nil || Analyses.shared.isQueued(key) || Analyses.shared.running.contains(key)
                }
                if pending { return nil }
                return ["results": keys.map { key -> [String: Any] in
                    let e = store.analysis.entry(for: key)
                    return ["key": key, "bpm": e?.bpm.map { ($0 * 100).rounded() / 100 } as Any? ?? NSNull(),
                            "musicalKey": e?.musicalKey.map { $0 as Any } ?? NSNull()]
                }]
            }

        case "add-to-playlist":
            let name = a["playlist"] as? String ?? ""
            let keys = a["keys"] as? [String] ?? []
            guard !name.isEmpty, !keys.isEmpty else { return done(false, "args: playlist, keys") }
            if let item = store.playlists.items.first(where: { $0.kind == .playlist && $0.name == name }) {
                store.addToPlaylist(keys, item.id)
            } else {
                store.addOwn(.playlist, into: nil, name: name, tracks: keys)
            }
            done(true, ["playlist": name, "keys": keys.count])

        case "collection-playlist-add":
            // Tracks an eine Playlist der Collection-Datei (Datei wird geschrieben, wenn Schreiben an ist)
            let name = a["playlist"] as? String ?? ""
            let keys = a["keys"] as? [String] ?? []
            guard !name.isEmpty, !keys.isEmpty else { return done(false, "args: playlist, keys") }
            guard let node = store.root.first(where: { $0.kind == .playlist && $0.name == name }) else {
                return done(false, "keine Playlist der Collection „\(name)“")
            }
            store.addToCollectionPlaylist(node.id, keys: keys)
            done(true, ["playlist": name, "keys": keys.count])

        case "mark-played":
            let keys = Set(a["keys"] as? [String] ?? [])
            history.setPlayed(history.played.union(keys))
            done(true, ["played": history.played.count])

        case "reset-played":
            if let keys = a["keys"] as? [String] { history.resetPlayed(keys: Set(keys)) } else { history.resetPlayed() }
            done(true, ["played": history.played.count])

        case "shot":
            let path = a["path"] as? String ?? ""
            guard !path.isEmpty, let w = MainWindow.window, let v = w.contentView else { return done(false, "kein Hauptfenster") }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return done(false, "Bild nicht möglich") }
            v.cacheDisplay(in: v.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return done(false, "PNG nicht möglich") }
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                done(true, ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh])
            } catch {
                done(false, "Schreiben: \(error.localizedDescription)")
            }

        case "quit":
            done(true, ["quitting": true])
            // erst die Antwort in der Ordnerpost, dann das übliche Beenden (Sitzung, Einstellungen, Dienste)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }

        case "setup-state":
            done(true, setupState())

        case "setup-step":
            guard let st = SetupFlow.Step(rawValue: a["step"] as? String ?? "") else { return done(false, "unbekannter Schritt") }
            SetupFlow.shared.open(st)
            done(true, setupState())

        case "setup-choose":
            let p = a["path"] as? String ?? ""
            guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return done(false, "Datei fehlt: \(p)") }
            SetupFlow.shared.chooseCollection(URL(fileURLWithPath: p), store: store)
            done(true, setupState())

        case "setup-close":
            SetupFlow.shared.close()
            done(true, setupState())

        case "crash-state":
            done(true, crashState())

        case "crash-close":
            CrashPrompt.shared.close()
            done(true, crashState())

        case "crash-open":
            // nur gemerkt (CrashLinks), nie im Browser
            CrashPrompt.shared.openIssue()
            done(true, crashState())

        case "update-check":
            Updater.shared.check(manual: true) { r in
                switch r {
                case .success(let c):
                    done(true, ["build": Updater.shared.currentBuild, "available": c.map { ["version": $0.manifest.version,
                                                                                         "build": $0.manifest.build,
                                                                                         "file": $0.manifest.file] as [String: Any] } ?? NSNull()])
                case .failure(let e): done(false, e.message)
                }
            }

        case "update-install", "update-rollback":
            let cb: @MainActor (Result<[String: Any], UpdateError>) -> Void = { r in
                switch r {
                case .success(let body): done(true, body)
                case .failure(let e): done(false, e.message)
                }
            }
            if req.command == "update-install" { Updater.shared.install(completion: cb) } else { Updater.shared.rollback(completion: cb) }

        case "window":
            // Grundfunktionen-Fenster wie aus dem Menü; im Ende-zu-Ende nie sichtbar, nur gemerkt (BasicWindows)
            switch a["id"] as? String ?? "" {
            case "about": AboutWindow.show()
            case "manual": ManualWindow.show()
            case "shortcuts": ShortcutWindow.show(keys: { [mix] in mix.prefs.keys })
            case "log": StatusLogWindow.show()
            case "backups": CollectionBackupWindow.show(store: store)
            default: return done(false, "unbekanntes Fenster")
            }
            done(true, ["recorded": BasicWindows.recorded])

        case "issue":
            // Fehlermeldung: nur die Adresse wird gemerkt (CrashLinks), nie im Browser
            CrashLinks.open(BugReport.url(BugReport.current()))
            done(true, ["opened": CrashLinks.recorded])

        case "backup-list":
            let dir = CollectionBackups.folder(for: store.sourceURL ?? LibraryStore.defaultNML)
            done(true, ["backups": CollectionBackups.list(in: dir).map { e -> [String: Any] in
                ["name": e.id, "tracks": CollectionBackups.trackCount(e.url) ?? -1, "bytes": e.bytes]
            }])

        case "backup-now":
            do {
                let url = try CollectionBackups.backupNow(store.sourceURL ?? LibraryStore.defaultNML)
                done(url != nil, ["name": url?.lastPathComponent ?? ""])
            } catch {
                done(false, error.localizedDescription)
            }

        case "backup-restore":
            let dir = CollectionBackups.folder(for: store.sourceURL ?? LibraryStore.defaultNML)
            guard let e = CollectionBackups.list(in: dir).first(where: { $0.id == (a["name"] as? String ?? "") }) else {
                return done(false, "Sicherung fehlt")
            }
            let r = CollectionRestore.run(e.url, store: store)
            done(r.ok, ["message": r.message, "tracks": r.tracks ?? -1])

        case "drag":
            done(false, "nicht verdrahtet: Ziehen läuft über Fenster-Ereignisse (NSDraggingInfo); "
                 + "Ersatz: load (Deck), add-to-playlist (Playlist)")

        default:
            done(false, "unbekannter Befehl: \(req.command)")
        }
    }

    // MARK: Helfer

    /// Quelle aus dem Text: collection | playlist:NAME | smartlist:NAME | folder:PFAD | explorer:PFAD | preparation | history
    private func source(_ id: String) -> BrowserSource? {
        if id == "collection" { return .collection }
        if id == "preparation" { return .preparation }
        if id == "history" { return .historyLive }
        if id.hasPrefix("playlist:") || id.hasPrefix("smartlist:") {
            let name = String(id.drop { $0 != ":" }.dropFirst())
            return Session.source("node:" + name, store: store)
        }
        if id.hasPrefix("folder:") { return Session.source(id, store: store) }
        if id.hasPrefix("explorer:") { return Session.source("folder:" + id.dropFirst(9), store: store) }
        return Session.source(id, store: store)
    }

    private func visibleRows(_ pane: BrowserPaneModel) -> [Track] {
        pane.rows(from: store, history: history, separators: mix.prefs.ui.tagSeparators, hidePlayed: mix.prefs.ui.hidePlayedTracks)
    }

    private func row(_ t: Track, index: Int) -> [String: Any] {
        ["index": index, "key": t.key, "artist": t.artist, "title": t.title, "bpm": t.bpm,
         "keyText": t.keyText, "played": history.played.contains(t.key)]
    }

    /// Stand wie PairDebug-Snapshot, dazu Bibliothek, Quellen, Auswahl, Pairing, Gespielt, Pfade
    private func snapshot() -> [String: Any] {
        var o = PairDebugResponder.snapshot(mix: mix)
        func count(_ n: PlaylistNode) -> (lists: Int, smart: Int, folders: Int) {
            var r = (0, 0, 0)
            for c in n.children {
                switch c.kind {
                case .playlist: r.0 += 1
                case .smartlist: r.1 += 1
                case .folder:
                    r.2 += 1
                    let s = count(c); r.0 += s.lists; r.1 += s.smart; r.2 += s.folders
                }
            }
            return r
        }
        let c = count(store.root)
        o["library"] = ["tracks": store.tracks.count, "playlists": c.lists, "smartlists": c.smart, "folders": c.folders,
                        "collection": store.sourceURL?.path ?? "", "loaded": store.sourceURL != nil]
        o["browser"] = (0..<2).map { i -> [String: Any] in
            let p = browser.pane(i)
            return ["source": Session.sourceID(p.source) ?? "", "search": p.search,
                    "selection": p.selection.sorted(), "rows": p.shown.count]
        }
        let peer: Any = PairLink.shared.peer.map { ["name": $0.name, "writes": $0.writes, "decks": $0.decks] as [String: Any] } ?? NSNull()
        o["pair"] = ["on": PairLink.shared.setup.on, "writes": PairLink.shared.setup.writes, "decks": PairLink.shared.setup.decks,
                     "connected": PairLink.shared.connected, "peer": peer, "service": PairLink.service]
        // Ausgabe: 0 = kein Gerät (Ende-zu-Ende), sonst die Geräte-Kennung des Ausgangs
        o["output"] = ["e2e": E2E.isActive, "deviceID": Int(mix.engine.outputDeviceID), "running": mix.engine.running,
                       "rate": mix.engine.outputRate] as [String: Any]
        o["played"] = ["count": history.played.count, "keys": history.played.sorted()]
        o["paths"] = ["settings": SettingsFile.url.path, "dataDir": DataDir.shared.path, "root": E2E.root?.path ?? "",
                      "suite": E2E.suite]
        return o
    }

    /// Einrichtung: Sheet offen, Schritt, Gründe der Prüfung beim Start, Collection
    private func setupState() -> [String: Any] {
        let f = SetupFlow.shared
        return ["shown": f.shown, "step": f.step.rawValue, "checked": f.checked, "reasons": f.reasons.map(\.rawValue),
                "firstLaunch": SetupFlow.firstLaunch, "suppressed": SetupFlow.suppressed,
                "collectionFound": FileManager.default.fileExists(atPath: LibraryStore.defaultNML.path),
                "collection": LibraryStore.defaultNML.path, "chosen": LibraryStore.chosenNML?.path ?? "",
                "loaded": store.sourceURL != nil, "tracks": store.tracks.count]
    }

    /// Absturz-Sheet: offen, Anzahl neuer Berichte, Name und bereinigter Text des gezeigten
    private func crashState() -> [String: Any] {
        let c = CrashPrompt.shared
        return ["shown": c.shown, "count": c.item?.count ?? 0, "file": c.item?.fileName ?? "", "text": c.item?.text ?? "",
                "title": c.item?.title ?? "", "opened": CrashLinks.recorded,
                "askAfterCrash": mix.prefs.ui.askAfterCrash, "folderSet": !mix.prefs.ui.crashReportFolder.isEmpty]
    }

    /// Antwort schreiben (atomar); body wird als JSON abgelegt
    private func reply(token: String?, command: String, ok: Bool, body: Any) {
        var o: [String: Any] = ["ok": ok, "command": command, "body": sanitized(body),
                                "at": PairDebugFile.timestamp(Date())]
        o["token"] = token ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
                                                                                  .fragmentsAllowed])
        else { return }
        let name = (token ?? "reply-\(Int(Date().timeIntervalSince1970 * 1000))") + ".json"
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let tmp = inbox.appendingPathComponent(".\(name).tmp")
        try? data.write(to: tmp, options: .atomic)
        try? FileManager.default.moveItem(at: tmp, to: inbox.appendingPathComponent(name))
    }

    /// NaN/Unendlich und fremde Typen in JSON-taugliche Werte
    private func sanitized(_ v: Any) -> Any {
        switch v {
        // JSONSerialization liefert Wahrheitswerte als NSNumber: erst prüfen, sonst werden sie 1/0
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue
        case let d as Double: return d.isFinite ? d : NSNull()
        case let d as [String: Any]: return d.mapValues { sanitized($0) }
        case let a as [Any]: return a.map { sanitized($0) }
        case let s as Set<String>: return s.sorted()
        case is NSNull: return NSNull()
        case let x as String: return x
        case let x as Bool: return x
        case let x as Int: return x
        case let x as UInt32: return Int(x)
        case let x as Int32: return Int(x)
        case let x as UInt64: return Int(exactly: x) ?? NSNull()
        default: return "\(v)"
        }
    }

    private func object(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    private func parsedBody(_ text: String) -> Any { PairDebugFile.parsed(text) }

    private func bundleValue(_ key: String) -> String { (Bundle.main.infoDictionary?[key] as? String) ?? "" }
}
