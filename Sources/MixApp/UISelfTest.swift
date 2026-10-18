import AppKit
import UniformTypeIdentifiers
import AVFoundation
import SwiftUI
import MixCore
import MixEngine

/// UI-Selbsttest (MIX741_SELFTEST=1 MIX741_UITEST=1): echtes Hauptfenster mit ContentView offscreen (unsichtbar, nie
/// vorne, App nie aktiv), synthetische Maus- und Tastaturereignisse über `NSWindow.sendEvent` / `NSApp.sendEvent`.
/// Ohne Collection (oder MIX741_UITEST_FIXTURE=1): kleine Collection mit erzeugten WAV-Dateien in einem temporären
/// Ordner. Audio stumm auf einem eingebauten Gerät, nichts gespeichert. Endet mit `UITEST OK` oder dem ersten Fehler.
@MainActor
enum UISelfTest {
    static func runIfRequested() {
        guard Session.isSelfTest, ProcessInfo.processInfo.environment["MIX741_UITEST"] == "1" else { return }
        run()
    }

    static func log(_ s: String) { print("[uitest] \(s)"); fflush(stdout) }

    static func fail(_ s: String) -> Never {
        log("FEHLER: \(s)")
        log("UITEST FEHLER")
        cleanup()
        exit(1)
    }

    static func skip(_ s: String) -> Never {
        log("übersprungen: \(s)")
        log("UITEST ÜBERSPRUNGEN")
        cleanup()
        exit(0)
    }

    static func check(_ ok: Bool, _ s: @autoclosure () -> String) { if !ok { fail(s()) } }

    /// Fixture-Ordner und Drop-Pasteboard weg
    static func cleanup() {
        UITestFixture.remove()
        UIDriver.dragPasteboard?.releaseGlobally()
        UIDriver.dragPasteboard = nil
    }

    static func run() -> Never {
        let t0 = Date()
        let env = ProcessInfo.processInfo.environment
        NSApplication.shared.setActivationPolicy(.prohibited)
        SelfTest.enabled = false   // kein Audio-Selbsttest aus ContentView.onAppear

        // eingebautes Gerät, stumm (wie WindowShot); Argument-Domäne danach zurück
        let defaults = E2E.defaults
        let args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        defaults.setVolatileDomain(args.merging(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                                                 "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0]) { $1 },
                                   forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)

        // feste Ansicht (Selbsttest speichert keine Einstellungen)
        var ui = mix.prefs.ui
        ui.zoom = 1
        ui.showMixer = false
        ui.deckCount = 2
        ui.browserLayout = .sideBySide
        ui.browserHeight = 330
        ui.statusBar = .auto
        ui.showMeters = true
        ui.showAllDeckRows()
        mix.prefs.ui = ui
        ZoomControl.apply(1)

        // Collection oder Fixture
        let store = LibraryStore(), history = HistoryStore(), browser = BrowserState()
        browser.store = store
        browser.history = history
        browser.separators = { [mix] in mix.prefs.ui.tagSeparators }
        func pick() -> [Track] {
            var seen = Set<String>()
            return Array(store.tracks.filter {
                $0.bpm > 100 && $0.bpm < 150 && $0.gridAnchorMs != nil && $0.fileExists && $0.duration > 15
                    && OverviewPolicy.fileState(path: $0.path) == .local && seen.insert($0.title).inserted
            }.prefix(3))
        }
        var tracks: [Track] = []
        let real = env["MIX741_UITEST_FIXTURE"] != "1" && FileManager.default.fileExists(atPath: LibraryStore.defaultNML.path)
        if real {
            store.load()
            spin(120, until: { !store.tracks.isEmpty })
            tracks = pick()
            log("collection: \(store.tracks.count) tracks")
        }
        if tracks.count < 3 {
            guard let nml = UITestFixture.make() else { skip("keine Collection, Fixture nicht angelegt") }
            store.load(nml)
            spin(30, until: { !store.tracks.isEmpty })
            tracks = pick()
            log("fixture: \(nml.path) · \(store.tracks.count) tracks")
        }
        guard tracks.count == 3 else { skip("keine 3 lokalen Tracks mit Grid") }
        for (i, t) in tracks.prefix(2).enumerated() { _ = mix.load(t, deck: i, force: true) }
        spin(30, until: { (0..<2).allSatisfy { mix.core.trackAudio($0) != nil } })
        guard (0..<2).allSatisfy({ mix.core.trackAudio($0) != nil }) else {
            if devs.isEmpty { skip("kein Audiogerät, Decks laden nicht") }
            fail("Decks laden nicht: \((0..<2).map { mix.deck($0).error ?? "-" })")
        }
        mix.pull()
        log("A: \(tracks[0].title) · B: \(tracks[1].title) · C: \(tracks[2].title)")

        let u = UIDriver(mix: mix, store: store, browser: browser, history: history)
        let cases: [(String, (UIDriver, [Track]) -> Void)] = [
            ("deck-menü", deckMenu), ("deck-menü-fläche", deckMenuArea), ("drop aufs deck", dropOnDeck), ("bereich in der wellenform", waveRange), ("wellenform greifen", waveGrab),
            ("spaltenbreite per doppelklick", fitColumn), ("statusleiste automatisch", autoStatusBar), ("statusleiste job", statusBarJob),
            ("tastenkürzel", shortcuts), ("werkzeugleiste", toolbar), ("zoom", zoom),
            ("edit-modus", editMode),
            ("groove", groove),
            ("daw-streifen", dawStrip),
            ("master-fx", masterFX),
            ("doppelklick", doubleClickReset),
            ("gestapelt", stackedSide),
            ("ungespielt", unplayed),
            ("vorbereiten", prepareMode),
            ("playlist-baum", playlistTree),
            ("collection-playlist-drop", collectionDrop),
            ("mehrfach-sortierung", multiSort),
            ("wellenform-preset", wavePreset),
            ("einstellungen-suche", settingsSearch),
            ("aufnahme", recording),
            ("linien", gridLines),
            ("rip", ripCheck),
            ("rip-bereich", ripRange),
            ("link", linkDiagnosis),
            ("auto-loop", autoLoop),
            ("deck-groessen", deckSizes),
            ("insert-slots", insertSlots),
            ("zweizeilig", twoLineRows),
            ("browser-höhe", splitDrag),
            ("audio-edit", audioEdit),
            ("audio-editor", audioEditor),
        ]
        let only = env["MIX741_UITEST_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        var n = 0
        for (name, f) in cases where only.map({ s in s.contains { name.hasPrefix($0) } }) ?? true {
            let t = Date()
            f(u, tracks)
            n += 1
            log(String(format: "ok %@ (%.2f s)", name, Date().timeIntervalSince(t)))
        }
        check(n > 0, "kein Fall passt zu MIX741_UITEST_ONLY")
        u.close()
        cleanup()
        log(String(format: "UITEST OK · %d fälle · %.1f s", n, Date().timeIntervalSince(t0)))
        exit(0)
    }

    /// Run-Loop pumpen und Ereignisse der App-Warteschlange zustellen (die App läuft im Test nicht über NSApp.run)
    static func spin(_ s: Double, step: () -> Void = {}, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(s)
        while Date() < end, !done() {
            step()
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }

    // MARK: Fälle

    /// Rechtsklick auf LINK in der Master-Clock: Menü „Link-Diagnose“ schreibt in die Statusleiste. Link bleibt aus
    /// (der Test tritt keiner laufenden Link-Session bei) – Meldung „Link ist aus“
    static func linkDiagnosis(_ u: UIDriver, _ t: [Track]) {
        let item = String(localized: "Link-Diagnose")
        guard let clock = u.named("clock") else { fail("Master-Clock-Leiste nicht gefunden") }
        check(!u.mix.state.linkEnabled, "Link ist im Test an")
        let r = u.frame(clock)
        var found: NSMenu?
        for x in stride(from: r.minX + 2, to: r.maxX, by: 6) {
            if let m = u.rightClick(at: NSPoint(x: x, y: r.midY)), m.items.contains(where: { $0.title == item }) { found = m; break }
        }
        guard let menu = found, let i = menu.items.firstIndex(where: { $0.title == item }) else { fail("Rechtsklick auf LINK: kein Menü mit „\(item)“") }
        menu.performActionForItem(at: i)
        let want = String(localized: "Link ist aus")
        func shown() -> Bool { StatusCenter.shared.log.active.contains { $0.text == want } }
        u.spin(1) { shown() }
        check(shown(), "Statusleiste ohne „\(want)“: \(StatusCenter.shared.log.active.map(\.text))")
    }

    /// Rechtsklick auf den Decktitel: Menü „Track bearbeiten …“ (aus der Hosting-View des Kopfs), Auslösen öffnet das
    /// Bearbeiten-Fenster (Sheet am Hauptfenster)
    static func deckMenu(_ u: UIDriver, _ t: [Track]) {
        let item = String(localized: "Track bearbeiten …")
        guard let hdr = u.named("A header") else { fail("Deck-Kopf A nicht gefunden") }
        let r = u.frame(hdr)
        // Titel liegt hinter Buchstabe und Cover: von links nach rechts bis zum ersten Menü mit dem Eintrag
        var found: (NSMenu, NSPoint)?
        for x in stride(from: r.minX + 2, to: r.minX + min(400, r.width), by: 6) {
            let p = NSPoint(x: x, y: r.midY)
            if let m = u.rightClick(at: p), m.items.contains(where: { $0.title == item }) { found = (m, p); break }
        }
        guard let (menu, p) = found else { fail("Rechtsklick auf den Decktitel: kein Menü mit „\(item)“") }
        log("menü am titel (x \(Int(p.x - r.minX))): " + menu.items.map(\.title).joined(separator: " · "))
        guard let i = menu.items.firstIndex(where: { $0.title == item }) else { fail("Eintrag fehlt") }
        menu.performActionForItem(at: i)
        u.spin(5) { u.window.attachedSheet != nil }
        let pane = u.browser.activePane
        check(pane.editSession != nil, "Bearbeiten-Sitzung nicht geöffnet")
        check(pane.editSession?.selection == [t[0].key], "Bearbeiten-Fenster für falschen Track: \(pane.editSession?.selection ?? [])")
        check(u.window.attachedSheet != nil, "Bearbeiten-Fenster (Sheet) nicht offen")
        pane.editSession = nil
        u.spin(5) { u.window.attachedSheet == nil }
        check(u.window.attachedSheet == nil, "Bearbeiten-Fenster schließt nicht")
    }

    /// Rechtsklick auf Übersicht, Cover-Spalte und Wellenform von Deck A: Track-Menü (Wellenform mit Bereich: „Track ▸“ oben).
    /// „Im Browser zeigen“ wählt den Track im aktiven Bereich (aus PREPARATION zurück auf TRACK COLLECTION). Spielend:
    /// „Auswerfen“ ausgegraut; Deck B auswerfen -> leer, Menü mit „Track laden …“, danach wieder geladen
    static func deckMenuArea(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, ui0 = mix.prefs.ui
        let edit = String(localized: "Track bearbeiten …"), reveal = String(localized: "Im Browser zeigen")
        let eject = String(localized: "Auswerfen")
        func has(_ m: NSMenu?, _ title: String) -> Bool { m?.items.contains { $0.title == title } ?? false }
        func overview(_ deck: String) -> NSRect? {
            guard let v = u.named("deck " + deck) else { return nil }
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            let dw = u.frame(v).width
            return all(v).compactMap { $0 as? LiveCanvasView }.map { u.frame($0) }
                .filter { $0.width > dw / 2 && $0.height >= 11 }.max { $0.height < $1.height }
        }
        guard let key = mix.deck(0).track?.key else { fail("Deck A ohne Track") }
        if mix.deck(0).playing { mix.togglePlay(0) }
        guard let ov = overview("A") else { fail("Deck A: Übersicht nicht gefunden") }
        let om = u.rightClick(at: NSPoint(x: ov.midX, y: ov.midY))
        check(has(om, edit) && has(om, reveal), "Rechtsklick auf die Übersicht: \(om?.items.map(\.title) ?? [])")
        check(om?.items.first { $0.title == eject }?.isEnabled == true, "Übersicht: „\(eject)“ ausgegraut, Deck steht")
        log("menü an der übersicht: " + (om?.items.map(\.title).joined(separator: " · ") ?? ""))

        // Cover als eigene Spalte
        defer { mix.prefs.ui = ui0; u.spin(0.5) }
        mix.prefs.ui.deckCoverSize = 120
        u.spin(3) { u.named("A cover") != nil }
        guard let cv = u.named("A cover").map({ u.frame($0) }) else { fail("Cover-Spalte fehlt") }
        let cm = u.rightClick(at: NSPoint(x: cv.midX, y: cv.midY))
        check(has(cm, edit) && has(cm, reveal), "Rechtsklick auf das Cover: \(cm?.items.map(\.title) ?? [])")

        // Wellenform: ohne Bereich das Track-Menü, mit Bereich dessen Menü und oben „Track ▸“
        guard let w = u.views.compactMap({ $0 as? WaveMouseView }).first(where: { $0.d == 0 }) else { fail("Wellenform A nicht gefunden") }
        mix.setRange(0, nil)
        let wr = u.frame(w)
        let wm = u.rightClick(at: NSPoint(x: wr.midX, y: wr.midY))
        check(has(wm, edit), "Rechtsklick in die Wellenform ohne Bereich: \(wm?.items.map(\.title) ?? [])")
        let pos = mix.position(0)
        mix.setRange(0, TrackRange(max(0, pos - 2), pos + 2))
        let rm = u.rightClick(at: NSPoint(x: wr.midX, y: wr.midY))
        mix.setRange(0, nil)
        check(rm?.items.first?.title == String(localized: "Track") && has(rm?.items.first?.submenu, edit)
              && has(rm, String(localized: "Bereich aufheben")), "Wellenform mit Bereich: \(rm?.items.map(\.title) ?? [])")

        // Im Browser zeigen
        let pane = u.browser.activePane, source0 = pane.source
        pane.selection = []
        pane.source = .preparation
        u.spin(0.5)
        guard let m = u.rightClick(at: NSPoint(x: cv.midX, y: cv.midY)), let ri = m.items.firstIndex(where: { $0.title == reveal }) else { fail("„\(reveal)“ fehlt") }
        check(m.items[ri].isEnabled, "„\(reveal)“ ausgegraut")
        m.performActionForItem(at: ri)
        u.spin(2) { pane.selection == [key] && pane.shown.contains { $0.key == key } }
        check(u.browser.activePane === pane && pane.selection == [key], "Im Browser zeigen: Auswahl \(pane.selection) statt \(key)")
        check(pane.shown.contains { $0.key == key }, "Im Browser zeigen: Track steht nicht in der Liste (Quelle \(pane.source))")
        pane.source = source0
        u.spin(0.3)

        // spielend: Auswerfen ausgegraut
        mix.togglePlay(0)
        u.spin(1) { mix.deck(0).playing }
        let pm = u.rightClick(at: NSPoint(x: ov.midX, y: ov.midY))
        mix.togglePlay(0)
        u.spin(1) { !mix.deck(0).playing }
        let pe = pm?.items.first { $0.title.hasPrefix(eject) }
        check(pe != nil && pe?.isEnabled == false, "Deck spielt: „\(eject)“ nicht ausgegraut: \(pm?.items.map(\.title) ?? [])")

        // Deck B auswerfen und wieder laden
        guard let ovb = overview("B"), let bm = u.rightClick(at: NSPoint(x: ovb.midX, y: ovb.midY)),
              let ei = bm.items.firstIndex(where: { $0.title == eject }) else { fail("Deck B: kein „\(eject)“") }
        bm.performActionForItem(at: ei)
        u.spin(1) { mix.deck(1).track == nil }
        check(mix.deck(1).track == nil && mix.core.trackAudio(1) == nil, "Deck B nach dem Auswerfen nicht leer")
        let em = u.rightClick(at: NSPoint(x: ovb.midX, y: ovb.midY))
        check(has(em, String(localized: "Track laden …")) && em?.items.first { $0.title == edit }?.isEnabled == false,
              "leeres Deck: \(em?.items.map(\.title) ?? [])")
        _ = mix.load(t[1], deck: 1, force: true)
        u.spin(30) { mix.core.trackAudio(1) != nil && mix.deck(1).grid != nil }
        check(mix.core.trackAudio(1) != nil, "Deck B lädt nach dem Auswerfen nicht")
    }

    /// Tracks aus der Tabelle auf ein Deck fallen lassen: auf den Kopf und auf die Wellenform (ganze Deckfläche), mehrere
    /// Zeilen laden die erste. Die Ziehen-Sitzung selbst braucht den Fensterserver und wird durch NSDraggingInfo ersetzt
    static func dropOnDeck(_ u: UIDriver, _ t: [Track]) {
        if u.mix.deck(0).playing { u.mix.togglePlay(0) }
        guard let hdr = u.named("A header") else { fail("Deck-Kopf A nicht gefunden") }
        // die Zeile der Tabelle A wie beim echten Ziehen: der Eintrag, den die Tabelle selbst schreibt
        guard let table = u.views.compactMap({ $0 as? TrackNSTable }).min(by: { u.frame($0).minX < u.frame($1).minX }),
              // erste ladbare Zeile (echte Collection: oben stehen auch Tracks, die nur online oder weg sind)
              let row = u.browser.paneA.shown.prefix(200).firstIndex(where: { $0.fileExists && CloudLibrary.shared.isLocal($0.path) }),
              let item = table.dataSource?.tableView?(table, pasteboardWriterForRow: row) as? NSPasteboardItem,
              let s = item.string(forType: .string) else { fail("Tabelle A: Zeile nicht ziehbar") }
        let key = String(s.dropFirst(TrackDrag.prefix.count))
        let r = u.frame(hdr)
        let ok = u.drop(string: s, at: NSPoint(x: r.midX, y: r.midY))
        check(ok, "Drop auf Deck A nicht angenommen")
        u.spin(30) { u.mix.deck(0).track?.key == key }   // echte Dateien (Cloud-Ordner) dekodieren länger als die Fixture
        check(u.mix.deck(0).track?.key == key, "Deck A hat nach dem Drop \(u.mix.deck(0).track?.title ?? "nichts") statt \(key) · spielt \(u.mix.deck(0).playing) · Meldung \(StatusCenter.shared.current.map { "\($0.level) \($0.text)" } ?? "-")")
        // Datei aus dem Finder auf Deck A: lädt den Track der Collection mit diesem Pfad
        let other = t[1]
        check(u.drop(file: URL(fileURLWithPath: other.path), at: NSPoint(x: r.midX, y: r.midY)), "Finder-Datei auf Deck A nicht angenommen")
        u.spin(30) { u.mix.deck(0).track?.key == other.key }
        check(u.mix.deck(0).track?.key == other.key, "Finder-Datei: Deck A hat \(u.mix.deck(0).track?.title ?? "nichts") statt \(other.title)")
        u.spin(30) { u.mix.core.trackAudio(0) != nil && u.mix.deck(0).grid != nil }
        check(u.mix.core.trackAudio(0) != nil, "Deck A lädt nach dem Drop nicht")
        // ganze Deckfläche: Wellenform von Deck B; mehrere Zeilen laden die erste (Reihenfolge der Tabelle)
        guard let deckB = u.named("deck B") else { fail("Deck B nicht gefunden") }
        if u.mix.deck(1).playing { u.mix.togglePlay(1) }
        let mid = u.center(deckB)
        check(u.drop(string: TrackDrag.prefix + t[2].key, at: mid), "Drop auf die Wellenform von Deck B nicht angenommen")
        u.spin(30) { u.mix.deck(1).track?.key == t[2].key }
        check(u.mix.deck(1).track?.key == t[2].key, "Wellenform B: Deck B hat \(u.mix.deck(1).track?.title ?? "nichts") statt \(t[2].title)")
        check(u.drop(strings: [TrackDrag.prefix + t[0].key, TrackDrag.prefix + t[1].key], at: mid), "Mehrfach-Drop auf Deck B nicht angenommen")
        u.spin(30) { u.mix.deck(1).track?.key == t[0].key }
        check(u.mix.deck(1).track?.key == t[0].key, "Mehrfach-Drop: Deck B hat \(u.mix.deck(1).track?.title ?? "nichts") statt des ersten Tracks \(t[0].title)")
    }

    /// ⌃ + Ziehen in der Wellenform von Deck A: Bereich auf Beats; Esc hebt ihn auf
    static func waveRange(_ u: UIDriver, _ t: [Track]) {
        guard let w = u.views.compactMap({ $0 as? WaveMouseView }).first(where: { $0.d == 0 }) else { fail("Wellenform A nicht gefunden") }
        u.mix.setRange(0, nil)
        u.mix.pull()
        let r = u.frame(w)
        log(String(format: "wellenform %.0f × %.0f pt · position %.3f s · dauer %.1f s · %.0f s/seite", r.width, r.height,
                   u.mix.position(0), u.mix.deck(0).duration, u.mix.prefs.ui.waveformSeconds))
        u.drag(from: NSPoint(x: r.minX + r.width * 0.56, y: r.midY), to: NSPoint(x: r.minX + r.width * 0.84, y: r.midY),
               modifiers: .control, steps: 8)
        guard let range = u.mix.range(0) else { fail("⌃ + Ziehen: kein Bereich") }
        guard let g = u.mix.deck(0).grid else { fail("Deck A ohne Grid") }
        let a = g.beatPosition(at: range.start), b = g.beatPosition(at: range.end)
        log(String(format: "bereich %.3f–%.3f s · beats %.3f–%.3f", range.start, range.end, a, b))
        check(range.length > g.beat, "Bereich zu kurz: \(range.length) s")
        check(abs(a - a.rounded()) < 1e-3 && abs(b - b.rounded()) < 1e-3, "Bereich nicht auf Beats: \(a) – \(b)")
        check(u.mix.focusedDeck == 0, "Klick in die Wellenform fokussiert Deck A nicht")
        guard let esc = u.mix.prefs.keys.combo(.rangeClear) else { fail("Esc nicht belegt") }
        u.key(esc)
        check(u.mix.range(0) == nil, "Esc hebt den Bereich nicht auf")
    }

    /// Wellenform greifen (⌘, -> DECKS) an Deck A: Vinyl folgt dem Zug (Position um die gezogene Strecke, auch im Stopp);
    /// Jog im Stopp sucht wie bisher; Jog spielend bleibt das Deck nach dem Loslassen am Laufen. ⌃ + Ziehen bleibt Bereich
    static func waveGrab(_ u: UIDriver, _ t: [Track]) {
        guard let w = u.views.compactMap({ $0 as? WaveMouseView }).first(where: { $0.d == 0 }) else { fail("Wellenform A nicht gefunden") }
        let mix = u.mix
        guard mix.deck(0).track != nil else { fail("Deck A ohne Track") }
        let saved = mix.prefs.ui.waveGrab
        defer { mix.prefs.ui.waveGrab = saved }
        if mix.deck(0).playing { mix.togglePlay(0); u.spin(1) { !mix.deck(0).playing } }
        mix.setRange(0, nil)
        let r = u.frame(w), spp = mix.prefs.ui.waveformSeconds * 2 / Double(r.width)
        // 40 pt nach links = vorwärts um 40 Punkte Zeit
        let want = 10 + 40 * spp
        func zug(_ grab: WaveGrab, playing: Bool) -> Double {
            mix.prefs.ui.waveGrab = grab
            mix.core.seek(0, seconds: 10)
            u.spin(0.3)
            if playing { mix.togglePlay(0); u.spin(0.3) }
            let p0 = mix.position(0)
            u.drag(from: NSPoint(x: r.midX + 60, y: r.midY), to: NSPoint(x: r.midX + 20, y: r.midY), steps: 8)
            let p1 = mix.position(0)
            log(String(format: "wellenform greifen %@ %@: %.3f → %.3f s", grab.rawValue, playing ? "spielend" : "steht", p0, p1))
            return p1 - p0
        }
        let v = zug(.vinyl, playing: false)
        check(abs(10 + v - want) < 0.03, "Vinyl: Zug um 40 pt hat die Position um \(v) s bewegt, erwartet \(want - 10)")
        check(!mix.deck(0).playing, "Vinyl: das stehende Deck ist nach dem Loslassen angelaufen")
        _ = zug(.jog, playing: false)
        check(abs(mix.position(0) - (10 + 40 * spp)) < 0.03, "Jog im Stopp: Suchen landet nicht dort, wo losgelassen wurde (\(mix.position(0)))")
        check(!mix.deck(0).playing, "Jog im Stopp: das Deck ist angelaufen")
        // spielend: kein Sprung, sondern Nudge; das Deck läuft nach dem Loslassen weiter
        _ = zug(.jog, playing: true)
        u.spin(0.3)
        check(mix.deck(0).playing, "Jog spielend: das Deck ist nach dem Loslassen stehen geblieben")
        check(mix.position(0) > 10 && mix.position(0) < 10 + 40 * spp + 1.5, "Jog spielend: Position \(mix.position(0)) springt")
        mix.togglePlay(0)
        u.spin(0.5) { !mix.deck(0).playing }
        // ⌃ + Ziehen: Bereich, keine Bewegung der Position
        mix.core.seek(0, seconds: 10)
        u.spin(0.3)
        u.drag(from: NSPoint(x: r.midX + 60, y: r.midY), to: NSPoint(x: r.midX + 20, y: r.midY), modifiers: .control, steps: 8)
        check(mix.range(0) != nil && abs(mix.position(0) - 10) < 0.03, "⌃ + Ziehen: Bereich fehlt oder die Position ist mitgewandert")
        mix.setRange(0, nil)
    }

    /// Doppelklick auf den Trenner rechts der Titel-Spalte im Kopf von Bereich A: Spalte auf den längsten Titel
    static func fitColumn(_ u: UIDriver, _ t: [Track]) {
        let pane = u.browser.paneA
        guard let head = u.views.compactMap({ $0 as? TrackHeaderView }).first(where: { h in
            guard let tv = h.tableView else { return false }
            return tv.numberOfRows == pane.shown.count && u.frame(h).minX < u.window.frame.width / 2
        }), let tv = head.tableView else { fail("Tabellenkopf von Bereich A nicht gefunden") }
        guard let i = tv.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" && !$0.isHidden }) else { fail("Spalte Titel fehlt") }
        let c = tv.tableColumns[i], before = c.width
        c.width = c.minWidth
        head.layoutSubtreeIfNeeded()
        let hr = head.headerRect(ofColumn: i)
        let p = head.convert(NSPoint(x: hr.maxX, y: hr.midY), to: nil)
        check(u.frame(head).contains(p), "Trenner liegt außerhalb des Kopfs")
        u.doubleClick(at: p)
        let longest = pane.shown.map(\.title.utf16.count).max() ?? 0
        log("spalte titel: \(c.minWidth) -> \(c.width) (längster titel \(longest) zeichen)")
        check(c.width > c.minWidth && c.width >= min(c.maxWidth, CGFloat(longest) * 5), "Doppelklick auf den Trenner: Breite \(c.width)")
        c.width = before
    }

    /// Statusleiste „Automatisch“: Maus an den unteren Rand -> sichtbar, Maus weg -> nach 0,5 s weg
    static func autoStatusBar(_ u: UIDriver, _ t: [Track]) {
        // Meldungen weg, Leiste neu aufgebaut (eine Warnung beim Laden zeigt sie sonst 6 s lang)
        for _ in 0..<50 { guard let m = StatusCenter.shared.current else { break }; StatusCenter.shared.dismiss(m) }
        u.mix.prefs.ui.statusBar = .always
        u.spin(0.3)
        u.mix.prefs.ui.statusBar = .auto
        u.spin(0.5)
        func visible() -> Bool? { barVisible(u) }
        guard let start = visible() else { fail("Pegelanzeige der Statusleiste nicht gefunden") }
        check(!start, "Statusleiste ohne Maus schon sichtbar")
        let mid = NSPoint(x: u.window.frame.width / 2, y: u.window.frame.height / 2)
        u.hover(at: mid)
        u.hover(at: NSPoint(x: u.window.frame.width / 2, y: 2))
        u.spin(1) { visible() == true }
        check(visible() == true, "Maus am unteren Rand: Statusleiste bleibt verborgen")
        u.hover(at: mid)
        u.spin(0.2)
        check(visible() == true, "Statusleiste verschwindet sofort (soll 0,4 s warten)")
        u.spin(0.6) { visible() == false }
        check(visible() == false, "Maus weg: Statusleiste nach 0,8 s noch sichtbar")
    }

    /// Pegelanzeige der Leiste (eigene NSView): sichtbar = im Fenster, nicht durchsichtig; nil = nicht gefunden
    static func barVisible(_ u: UIDriver) -> Bool? {
        guard let v = u.views.compactMap({ $0 as? LiveCanvasView }).filter({ u.frame($0).minY < 60 }).min(by: { u.frame($0).minY < u.frame($1).minY }) else { return nil }
        let f = u.frame(v)
        var alpha: CGFloat = 1, a: NSView? = v
        while let x = a { alpha *= x.alphaValue * CGFloat(x.layer?.opacity ?? 1); a = x.superview }
        return f.minY >= 0 && alpha > 0.5
    }

    /// Statusleiste „Automatisch“ bei einem Hintergrundjob: Analyse von drei Tracks -> Leiste fährt hoch und bleibt oben,
    /// die laufende Meldung trägt Track und Fortschritt; nach dem Ende 3 s die Schlussmeldung, dann weg
    static func statusBarJob(_ u: UIDriver, _ t: [Track]) {
        for _ in 0..<50 { guard let m = StatusCenter.shared.current else { break }; StatusCenter.shared.dismiss(m) }
        u.mix.prefs.ui.statusBar = .always
        u.spin(0.3)
        u.mix.prefs.ui.statusBar = .auto
        u.spin(0.5)
        guard barVisible(u) != nil else { fail("Pegelanzeige der Statusleiste nicht gefunden (Job)") }
        check(barVisible(u) == false, "Statusleiste ohne Job schon sichtbar")
        Analyses.shared.enqueue(Array(t.prefix(3)), refresh: true)
        u.spin(5) { StatusCenter.shared.jobCount > 0 && barVisible(u) == true }
        guard StatusCenter.shared.jobCount > 0 else { fail("Analyse startet keinen Hintergrundjob: \(StatusCenter.shared.current.map(\.text) ?? "-")") }
        check(barVisible(u) == true, "Analyse läuft, Statusleiste bleibt verborgen")
        // Laufende Meldung: Art, Fortschritt, Track (wenn schon einer rechnet)
        u.spin(10) { StatusCenter.shared.log.active.contains { $0.job && $0.detail != nil } || StatusCenter.shared.jobCount == 0 }
        if let m = StatusCenter.shared.log.active.first(where: { $0.job }) {
            check(m.progress != nil && m.progressText?.contains("/") == true, "Analyse-Meldung ohne Stand: \(m.text) · \(m.progressText ?? "-")")
            check(m.cancellable, "Analyse-Meldung ohne ✕")
        }
        // Ende: Schlussmeldung 3 s oben, dann weg
        u.spin(120) { StatusCenter.shared.jobCount == 0 }
        check(StatusCenter.shared.jobCount == 0, "Analyse nach 120 s nicht fertig")
        u.spin(1) { barVisible(u) == false }
        check(barVisible(u) == true, "nach dem Ende fehlt die Schlussmeldung")
        u.spin(5) { barVisible(u) == false }
        check(barVisible(u) == false, "Analyse fertig: Statusleiste nach 3 s noch sichtbar")
    }

    /// Play/Pause auf Deck A per Kürzel aus den Einstellungen; Taste ohne ⌘/⌥/⌃ im Suchfeld: Deck reagiert nicht
    static func shortcuts(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        if mix.deck(0).playing { mix.togglePlay(0) }
        u.spin(0.2)
        u.window.makeFirstResponder(nil)
        mix.focusedDeck = 0
        guard let play = mix.prefs.keys.combo(.play) else { fail("Play/Pause nicht belegt") }
        u.key(play)
        u.spin(1) { mix.deck(0).playing }
        check(mix.deck(0).playing, "\(play.symbols): Deck A spielt nicht")
        u.key(play)
        u.spin(1) { !mix.deck(0).playing }
        check(!mix.deck(0).playing, "\(play.symbols): Deck A stoppt nicht")
        // Taste ohne Modifier für Play/Pause (nur flüchtig), außerhalb und im Suchfeld
        let keys = mix.prefs.keys
        guard let plain = ["q", "j", "z"].map({ KeyCombo($0, []) }).first(where: { keys.action(for: $0) == nil }) else { fail("keine freie Taste") }
        let name = plain.symbols
        mix.prefs.keys.set(.play, plain)
        defer { mix.prefs.keys = keys }
        check(mix.prefs.keys.action(for: plain) == .play, "\(name) nicht Play/Pause")
        u.key(plain)
        u.spin(1) { mix.deck(0).playing }
        check(mix.deck(0).playing, "\(name) ohne Textfeld: Deck A spielt nicht")
        u.key(plain)
        u.spin(1) { !mix.deck(0).playing }
        guard let field = u.searchField(pane: 0) else { fail("Suchfeld von Bereich A nicht gefunden") }
        u.click(at: u.center(field))
        u.spin(0.3)
        check(u.window.firstResponder is NSText, "Klick ins Suchfeld: kein Texteditor (Ersthelfer \(u.window.firstResponder.map { "\(type(of: $0))" } ?? "-"))")
        let big = u.browser.maximized
        u.key(plain)
        u.key(KeyCombo("space", []))   // Browser groß (Leertaste) darf im Suchfeld auch nicht schalten
        u.spin(0.5)
        check(!mix.deck(0).playing, "\(name) im Suchfeld startet Deck A")
        check(u.browser.maximized == big, "Leertaste im Suchfeld schaltet Browser groß")
        check(field.stringValue == plain.key + " ", "Suchfeld hat „\(field.stringValue)“ statt „\(plain.key) “")
        u.type("x")
        check(field.stringValue == plain.key + " x", "Tippen ins Suchfeld: „\(field.stringValue)“")
        field.stringValue = ""
        u.browser.paneA.search = ""
        u.window.makeFirstResponder(nil)
        u.spin(0.3)
    }

    /// Werkzeugleiste: MIXER und Decks 1 / 2 / 4 per Klick (Schalter tragen Marken, WindowBar.swift)
    static func toolbar(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        // ohne Fensterserver (CI-Runner) baut AppKit die Elemente der Werkzeugleiste nicht auf: dann nur melden, nicht scheitern
        guard let mixer = u.named("toolbar mixer"), u.named("toolbar decks 4") != nil else {
            log("werkzeugleiste nicht aufgebaut – fall übersprungen")
            return
        }
        let m0 = mix.prefs.ui.showMixer
        u.click(at: u.center(mixer))
        u.spin(1) { mix.prefs.ui.showMixer != m0 }
        check(mix.prefs.ui.showMixer != m0, "Klick auf MIXER schaltet nicht")
        u.click(at: u.center(mixer))
        u.spin(1) { mix.prefs.ui.showMixer == m0 }
        check(mix.prefs.ui.showMixer == m0, "zweiter Klick auf MIXER schaltet nicht zurück")
        // Decks 1 / 2 / 4: Klick auf die Marke des Schalters
        func click(_ n: Int) {
            guard let b = u.named("toolbar decks \(n)") else { fail("Decks: kein Schalter „\(n)“") }
            u.click(at: u.center(b))
            u.spin(1) { mix.prefs.ui.deckCount == n }
            check(mix.prefs.ui.deckCount == n, "Klick auf „\(n)“: \(mix.prefs.ui.deckCount) Decks")
        }
        check(mix.prefs.ui.deckCount == 2, "Ausgangslage nicht 2 Decks")
        click(4)
        u.spin(1) { u.named("deck C") != nil }
        check(u.named("deck C") != nil, "4 Decks: Deck C nicht aufgebaut")
        click(1)
        u.spin(1) { u.named("deck B") == nil }
        check(u.named("deck B") == nil, "1 Deck: Deck B noch sichtbar")
        click(2)
        u.spin(1) { u.named("deck B") != nil }
        check(u.named("deck B") != nil && u.named("deck C") == nil, "2 Decks: Decks nicht wie erwartet")
    }

    /// Zoom ⌘− / ⌘+ (Kürzel aus den Einstellungen): Faktor der Oberfläche
    static func zoom(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        guard let zin = mix.prefs.keys.combo(.zoomIn), let zout = mix.prefs.keys.combo(.zoomOut) else { fail("Zoom nicht belegt") }
        check(UIZoom.shared.factor == 1, "Zoom nicht bei 100 %")
        u.key(zout)
        u.spin(0.3)
        check(abs(UIZoom.shared.factor - 0.9) < 0.001, "\(zout.symbols): Zoom \(UIZoom.shared.factor) statt 0.9")
        u.key(zin)
        u.spin(0.3)
        check(UIZoom.shared.factor == 1, "\(zin.symbols): Zoom \(UIZoom.shared.factor) statt 1")
    }
}

/// Fenster des UI-Tests: weit außerhalb jedes Bildschirms, durchsichtig, gilt als Schlüsselfenster
/// (die App wird im Test nie aktiv, damit sie niemandem den Fokus nimmt)
final class UITestWindow: NSWindow {
    static let origin = NSPoint(x: -30000, y: -30000)
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
    /// nie auf einen Bildschirm verschieben (Zoom vergrößert das Hauptfenster „im Bildschirm“)
    override func setFrame(_ r: NSRect, display: Bool) { super.setFrame(NSRect(origin: Self.origin, size: r.size), display: display) }
    /// zuletzt zugestellte Taste (die App stellt sie im inaktiven Zustand nicht selbst zu)
    private(set) weak var lastKey: NSEvent?
    /// Ansicht unter dem letzten Drücken: Ziehen und Loslassen gehen dorthin
    private weak var downView: NSView?
    /// vorab abgelegtes Loslassen für die Verfolgungsschleifen der Steuerelemente (NSControl holt es über
    /// `window.nextEvent`). Nicht über die App-Warteschlange: dort gepostete Mausereignisse verlieren ihre Position
    /// (das Fenster liegt außerhalb aller Bildschirme, AppKit ordnet sie beim Abholen neu zu)
    var pending: [NSEvent] = []
    func takePending(_ mask: NSEvent.EventTypeMask, dequeue: Bool) -> NSEvent? {
        guard let i = pending.firstIndex(where: { mask.contains(NSEvent.EventTypeMask(type: $0.type)) }) else { return nil }
        let e = pending[i]
        if dequeue { pending.remove(at: i) }
        return e
    }
    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue: Bool) -> NSEvent? {
        if let e = takePending(mask, dequeue: dequeue) { return e }
        return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
    }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown || e.type == .keyUp { lastKey = e }
        // Die App ist im Test meist nicht aktiv (Christian arbeitet weiter): AppKit nähme den ersten Klick dann nur zum
        // Aktivieren und stellte ihn nur Ansichten mit acceptsFirstMouse zu (Wellenform ja, Tabellenkopf nein) – Maus-
        // ereignisse deshalb selbst an die getroffene Ansicht geben, wie bei aktiver App
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            let v = (contentView?.superview ?? contentView)?.hitTest(e.locationInWindow)
            if e.type == .leftMouseDown { downView = v }
            if let v { e.type == .leftMouseDown ? v.mouseDown(with: e) : v.rightMouseDown(with: e); return }
        case .leftMouseDragged:
            if let v = downView { v.mouseDragged(with: e); return }
        case .leftMouseUp:
            if let v = downView { downView = nil; v.mouseUp(with: e); return }
        default: break
        }
        super.sendEvent(e)
    }
}

/// NSApp.keyWindow im Test: das Testfenster (Klasse von NSApp nur in diesem Prozess getauscht, keine eigenen Felder)
final class UITestApplication: NSApplication {
    nonisolated(unsafe) static weak var testWindow: NSWindow?
    override var keyWindow: NSWindow? { Self.testWindow ?? super.keyWindow }
    /// Verfolgungsschleifen der Steuerelemente holen das Loslassen hier oder über das Fenster: vorab abgelegte Ereignisse zuerst
    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue: Bool) -> NSEvent? {
        if let e = (Self.testWindow as? UITestWindow)?.takePending(mask, dequeue: dequeue) { return e }
        return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
    }
}

/// Hosting-Views mit Namen (Deck, Deck-Zeilen)
protocol UITestNamed: AnyObject { var name: String { get } }
extension BoundaryHostingView: UITestNamed {}

/// Fenster mit ContentView und Helfern für Ereignisse
@MainActor
final class UIDriver {
    let mix: MixModel
    let store: LibraryStore
    let browser: BrowserState
    let window: UITestWindow
    let host: NSView
    private var eventNumber = 0
    private var inside: Set<ObjectIdentifier> = []
    /// eigenes Pasteboard für Drops (nie das allgemeine), am Ende freigegeben
    static var dragPasteboard: NSPasteboard?

    init(mix: MixModel, store: LibraryStore, browser: BrowserState, history: HistoryStore) {
        self.mix = mix
        self.store = store
        self.browser = browser
        let root = ContentView()
            .environment(store).environment(mix).environment(browser)
            .environment(ControllerStatus()).environment(WaveformCache()).environment(history)
        let h = NSHostingView(rootView: root)
        h.sceneBridgingOptions = [.toolbars]
        host = h
        let size = NSSize(width: 1700, height: 1100)
        window = UITestWindow(contentRect: NSRect(origin: UITestWindow.origin, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true   // echte Maus erreicht das Fenster nie
        window.appearance = NSAppearance(named: .darkAqua)
        window.toolbarStyle = .unified
        window.title = MixApp.appTitle
        window.contentView = h
        window.setContentSize(size)
        window.orderFrontRegardless()   // Werkzeugleiste und Sheets brauchen ein geordnetes Fenster
        object_setClass(NSApp, UITestApplication.self)
        UITestApplication.testWindow = window
        KeyMonitor.install(AppActions(mix: mix, browser: browser, store: store, history: history))
        let built = { [unowned self] in
            self.views.contains { $0 is TrackHeaderView } && self.named("A header") != nil && self.window.toolbar?.items.isEmpty == false
        }
        spin(10, until: built)
        UISelfTest.check(built(), "Fenster nicht aufgebaut")
        spin(0.5)
    }

    func close() {
        UITestApplication.testWindow = nil
        window.orderOut(nil)
    }

    func spin(_ s: Double, until done: () -> Bool = { false }) {
        UISelfTest.spin(s, step: { [mix, host] in mix.pull(); host.layoutSubtreeIfNeeded() }, until: done)
    }

    // MARK: Suche

    var views: [NSView] {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(window.contentView?.superview ?? host)
    }

    func named(_ name: String) -> NSView? { views.first { ($0 as? UITestNamed)?.name == name } }

    /// Rahmen in Fensterkoordinaten
    func frame(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }
    func center(_ v: NSView) -> NSPoint { let r = frame(v); return NSPoint(x: r.midX, y: r.midY) }

    /// Suchfeld eines Browser-Bereichs (0 = links)
    func searchField(pane: Int) -> NSTextField? {
        let fields = views.compactMap { $0 as? NSTextField }
            .filter { $0.isEditable && $0.placeholderString == String(localized: "SUCHEN") }
            .sorted { frame($0).minX < frame($1).minX }
        return pane < fields.count ? fields[pane] : nil
    }

    /// erstes Steuerelement in einer Ansicht (Werkzeugleiste: SwiftUI-Schalter und -Picker sind AppKit-Steuerelemente)
    func control(in v: NSView) -> NSControl? {
        if let c = v as? NSControl { return c }
        for s in v.subviews { if let c = control(in: s) { return c } }
        return nil
    }

    // MARK: Maus

    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ mods: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
                                  pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Klick: Loslassen vorab beim Fenster ablegen (Steuerelemente verfolgen die Maus in einer eigenen Schleife und holen es
    /// dort), dann Drücken ans Fenster; blieb das Loslassen liegen, geht es hinterher an die gedrückte Ansicht.
    /// `viaApp`: Drücken durch die App (Ereignis-Monitore wie der Doppelklick-Fänger der Regler sehen nur diesen Weg)
    func click(at p: NSPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1, viaApp: Bool = false) {
        let up = mouse(.leftMouseUp, p, modifiers, clicks: count)
        window.pending.append(up)
        let down = mouse(.leftMouseDown, p, modifiers, clicks: count)
        if viaApp { NSApp.sendEvent(down) } else { window.sendEvent(down) }
        if let i = window.pending.firstIndex(of: up) { window.pending.remove(at: i); window.sendEvent(up) }
        spin(0.05)
    }

    func doubleClick(at p: NSPoint) {
        click(at: p, count: 1)
        click(at: p, count: 2, viaApp: true)
    }

    /// Kontextmenü am Punkt ohne Anzeige: `menu(for:)` der getroffenen Ansicht und ihrer Eltern (NSHostingView liefert
    /// das SwiftUI-`contextMenu`). Ein echter Rechtsklick öffnet das Menü modal (blockiert)
    func rightClick(at p: NSPoint) -> NSMenu? {
        let e = mouse(.rightMouseDown, p)
        var v = (window.contentView?.superview ?? host).hitTest(p)
        while let x = v {
            if let m = x.menu(for: e) { m.update(); return m }
            v = x.superview
        }
        return nil
    }

    /// Ziehen: Drücken, `steps` Bewegungen, Loslassen
    /// Ziehen: alles direkt ans Fenster. Über die Warteschlange gepostete Zieh-Ereignisse kommen ohne ihre Position an
    /// (das Fenster ignoriert die Maus, AppKit ordnet sie beim Abholen neu zu) – der Bereich landete dann bei 0 s
    /// `each`: nach jedem Schritt aufrufen (Messung während des Ziehens)
    func drag(from a: NSPoint, to b: NSPoint, modifiers: NSEvent.ModifierFlags = [], steps: Int = 6, each: (() -> Void)? = nil) {
        window.sendEvent(mouse(.leftMouseDown, a, modifiers))
        for i in 1...max(1, steps) {
            let f = CGFloat(i) / CGFloat(max(1, steps))
            window.sendEvent(mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), modifiers))
            if let each { spin(0.05); each() }
        }
        window.sendEvent(mouse(.leftMouseUp, b, modifiers))
        spin(0.2)
    }

    /// Maus an einen Punkt: Betreten / Verlassen / Bewegen an die Besitzer der Tracking-Areas (Ansichten), wie AppKit sie
    /// bei echter Bewegung zustellt – synthetische Ereignisse lösen keine Tracking-Areas aus
    func hover(at p: NSPoint) {
        for v in views {
            for area in v.trackingAreas {
                guard let owner = area.owner as? NSView else { continue }   // Tooltips u. a. nicht
                let rect = v.convert(area.options.contains(.inVisibleRect) ? v.visibleRect : area.rect, to: nil)
                let id = ObjectIdentifier(area), now = rect.contains(p), was = inside.contains(id)
                if area.options.contains(.mouseEnteredAndExited), now != was {
                    eventNumber += 1
                    let e = NSEvent.enterExitEvent(with: now ? .mouseEntered : .mouseExited, location: p, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: eventNumber, trackingNumber: 0, userData: nil)!
                    if now { owner.mouseEntered(with: e) } else { owner.mouseExited(with: e) }
                }
                if now { inside.insert(id) } else { inside.remove(id) }
                if now, area.options.contains(.mouseMoved) { owner.mouseMoved(with: mouse(.mouseMoved, p)) }
            }
        }
        spin(0.05)
    }

    /// Trefferkette für Meldungen (Diagnose eines fehlgeschlagenen Ziehens)
    static func chain(_ v: NSView?) -> String {
        var out: [String] = []
        var c = v
        while let x = c, out.count < 10 {
            out.append(String(describing: Swift.type(of: x)).prefix(40) + (x.registeredDraggedTypes.isEmpty ? "" : "[\(x.registeredDraggedTypes.count)]"))
            c = x.superview
        }
        return out.joined(separator: " < ")
    }

    /// angemeldet für einen der Typen des Zugs (Typen gleich oder ein Untertyp davon, wie AppKit es abgleicht)
    static func accepts(_ v: NSView, _ types: [NSPasteboard.PasteboardType]) -> Bool {
        v.registeredDraggedTypes.contains { reg in
            types.contains { t in
                if t == reg { return true }
                guard let a = UTType(t.rawValue), let b = UTType(reg.rawValue) else { return false }
                return a.conforms(to: b)
            }
        }
    }

    /// Ziehen und Ablegen eines Texts (Pasteboard) auf die Ansicht am Punkt, die Ziehen annimmt. Wie AppKit: die innerste
    /// Ansicht unter dem Zeiger (Trefferkette), dann aufwärts bis zur ersten, die für die Typen des Zugs angemeldet ist.
    /// Ist keine Ansicht angemeldet, nimmt AppKit den Zug nicht an (dann ist die Ablage kaputt, nicht der Test zu lax)
    /// `string`: Text-Eintrag (eigene Tracks); `strings`: je Zeile ein Eintrag; `file`: Dateieintrag wie vom Finder
    func drop(string: String? = nil, strings: [String] = [], file: URL? = nil, at p: NSPoint) -> Bool {
        let pb = UIDriver.dragPasteboard ?? NSPasteboard.withUniqueName()
        UIDriver.dragPasteboard = pb
        pb.clearContents()
        let texts = strings + (string.map { [$0] } ?? [])
        // je Zeile ein Eintrag, wie die Tabelle sie schreibt (Reihenfolge der Zeilen bleibt)
        if texts.count == 1 { pb.setString(texts[0], forType: .string) } else if texts.count > 1 {
            pb.writeObjects(texts.map { s in let i = NSPasteboardItem(); i.setString(s, forType: .string); return i })
        }
        if let file { pb.setString(file.absoluteString, forType: .fileURL) }
        // Zug aus Tabelle oder Baum: Beginn wie beim echten Ziehen (Tabelle: willBeginAt; Baum: gedrückt gezogen), vor dem Treffer
        let tree = texts.contains { $0.hasPrefix(TrackDrag.prefix) || $0.hasPrefix(TreeDrag.prefix) }
        let held = TreeDragGate.buttonHeld
        if tree { TreeDragGate.begin(); TreeDragGate.buttonHeld = { true } }
        defer { if tree { TreeDragGate.end(); TreeDragGate.buttonHeld = held } }
        let root = window.contentView?.superview ?? window.contentView
        var v = root?.hitTest(root?.convert(p, from: nil) ?? .zero)
        while let c = v, !UIDriver.accepts(c, pb.types ?? []) { v = c.superview }
        guard let target = v else {
            UISelfTest.log("ziel nicht gefunden · Trefferkette: " + UIDriver.chain(root?.hitTest(root?.convert(p, from: nil) ?? .zero)))
            return false
        }
        let info = UITestDragInfo(window: window, location: p, pasteboard: pb)
        // wie beim echten Ziehen: Betreten, einige Bewegungen über dem Ziel (SwiftUI wertet sie im nächsten Durchlauf aus), Ablegen
        guard target.draggingEntered(info) != [] else { return false }
        for _ in 0..<3 {
            spin(0.05)
            guard target.draggingUpdated(info) != [] else { return false }
        }
        guard target.prepareForDragOperation(info), target.performDragOperation(info) else { return false }
        target.concludeDragOperation(info)
        spin(0.05)
        return true
    }

    // MARK: Tastatur

    /// Taste über NSApp.sendEvent (lokale Monitore wie der KeyMonitor sehen sie), danach Loslassen
    func key(_ c: KeyCombo) {
        var flags: NSEvent.ModifierFlags = []
        if c.mods.contains(.control) { flags.insert(.control) }
        if c.mods.contains(.option) { flags.insert(.option) }
        if c.mods.contains(.shift) { flags.insert(.shift) }
        if c.mods.contains(.command) { flags.insert(.command) }
        let code = KeyCombo.keyCodes.first { $0.value == c.key }?.key ?? 0
        let chars: String = switch c.key {
        case "space": " "
        case "escape": "\u{1b}"
        case "return": "\r"
        case "tab": "\t"
        case "delete": "\u{7f}"
        default: KeyCombo.keyCodes.values.contains(c.key) ? "" : c.key
        }
        key(chars, code: code, flags: flags)
    }

    /// Text tippen (Tasten ohne Modifier)
    func type(_ text: String) {
        for ch in text { key(String(ch), code: 0, flags: []) }
    }

    /// NSApp.sendEvent ruft die lokalen Monitore (KeyMonitor), stellt die Taste der inaktiven App aber nicht ans Fenster
    /// zu. Das übernimmt der Test für Tasten ohne ⌘/⌥/⌃ in einem Textfeld (die lässt der KeyMonitor durch); ob ein
    /// Monitor eine Taste verbraucht hat, verrät AppKit nicht
    private func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(e)
            if window.lastKey !== e, flags.isDisjoint(with: [.command, .option, .control]), window.firstResponder is NSText {
                window.sendEvent(e)
            }
        }
        spin(0.05)
    }
}

/// Ziehen-Information für einen Drop ohne Fensterserver
final class UITestDragInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggingPasteboard = pasteboard
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard let items = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) else { return }
        var stop: ObjCBool = false
        for (i, o) in items.enumerated() {
            guard let w = o as? NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: w), i, &stop)
            if stop.boolValue { break }
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// kleine Collection für Rechner ohne eigene: 3 WAV-Dateien (20 s, Kick auf jedem Beat, leises Rauschen) und eine NML
/// mit Tempo, Key und Grid-Anker in einem temporären Ordner; wird am Ende gelöscht
@MainActor
enum UITestFixture {
    private(set) static var dir: URL?

    static func make() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-uitest-\(getpid())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.dir = dir
            let specs: [(String, String, Double, Int)] = [
                ("ui-a.wav", "Fixture Alpha", 128, 21),
                ("ui-b.wav", "Fixture Beta", 126, 9),
                ("ui-c.wav", "Fixture Gamma With A Deliberately Long Title For The Column Fit Check", 130, 14),
            ]
            var entries = ""
            for (file, title, bpm, key) in specs {
                let url = dir.appendingPathComponent(file)
                try writeWave(url, bpm: bpm, seconds: 20)
                let comps = dir.standardizedFileURL.path.split(separator: "/").map(String.init)
                let nmlDir = "/:" + comps.map { xml($0) + "/:" }.joined()
                entries += """
                <ENTRY TITLE="\(xml(title))" ARTIST="MINOS-741 UI Test"><LOCATION DIR="\(nmlDir)" FILE="\(file)" VOLUME="Macintosh HD"></LOCATION>
                <INFO COMMENT="ui test fixture" RATING="test" PLAYTIME="20" PLAYTIME_FLOAT="20.000000"></INFO>
                <TEMPO BPM="\(bpm)"></TEMPO><MUSICAL_KEY VALUE="\(key)"></MUSICAL_KEY>
                <CUE_V2 NAME="AutoGrid" TYPE="4" START="0.000000" LEN="0" HOTCUE="0"></CUE_V2></ENTRY>

                """
            }
            // Leere Playlists hinter den Testlisten: die Zeilen der Testlisten bleiben über dem unteren Rand des Fensters
            let trailing = (1...6).map { "<NODE TYPE=\"PLAYLIST\" NAME=\"UI Ende \($0)\"><PLAYLIST ENTRIES=\"0\" TYPE=\"LIST\" UUID=\"ende\($0)0000000000000000000000000\"></PLAYLIST></NODE>" }.joined(separator: "\n")
            let nml = """
            <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
            <NML VERSION="19"><COLLECTION ENTRIES="\(specs.count)">
            \(entries)</COLLECTION>
            <PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="8">
            <NODE TYPE="PLAYLIST" NAME="UI Collection"><PLAYLIST ENTRIES="0" TYPE="LIST" UUID="0123456789abcdef0123456789abcdef"></PLAYLIST></NODE>
            <NODE TYPE="SMARTLIST" NAME="UI Smart"><SMARTLIST UUID="fedcba9876543210fedcba9876543210"><SEARCH_EXPRESSION QUERY="$COMMENT % &quot;fixture&quot;"></SEARCH_EXPRESSION></SMARTLIST></NODE>
            \(trailing)
            </SUBNODES></NODE></PLAYLISTS></NML>
            """
            let url = dir.appendingPathComponent("collection.nml")
            try nml.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            UISelfTest.log("fixture: \(error)")
            return nil
        }
    }

    static func remove() {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
        self.dir = nil
    }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func writeWave(_ url: URL, bpm: Double, seconds: Double) throws {
        let rate = 44100.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let n = AVAudioFrameCount(rate * seconds)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n), let ch = buf.floatChannelData else {
            throw CocoaError(.fileWriteUnknown)
        }
        buf.frameLength = n
        let beat = 60 / bpm
        var seed: UInt32 = 741
        for i in 0..<Int(n) {
            let t = Double(i) / rate
            let k = t.truncatingRemainder(dividingBy: beat)
            let kick = sin(2 * .pi * (50 + 120 * exp(-k * 40)) * k) * exp(-k * 12)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = (Double(seed >> 8) / Double(1 << 24) - 0.5) * 0.05
            let v = Float(kick * 0.8 + noise)
            for c in 0..<Int(file.processingFormat.channelCount) { ch[c][i] = v }
        }
        try file.write(from: buf)
    }
}

extension UISelfTest {
    /// EDIT-Modus auf Deck A: Ziehen ohne Taste markiert auf dem Raster, Klick setzt eine Schnittmarke, Rechtsklick ->
    /// „Bereich entfernen“ (Deck spielt die kürzere Liste), ⌘Z zurück, Tool-Loop 4 als Datei (Test-Ordner)
    static func editMode(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, d = 0
        if mix.deck(d).playing { mix.togglePlay(d) }
        let wasEditing = mix.editing(d)
        mix.setEditing(d, true)
        u.spin(5) { mix.editSession(d) != nil }
        guard let session = mix.editSession(d) else { fail("EDIT: keine Sitzung auf Deck A") }
        if session.shown.segments.count > 1 { mix.editReset(d); u.spin(5) { mix.editSession(d)?.rendering == false } }
        guard let w = u.views.compactMap({ $0 as? WaveMouseView }).first(where: { $0.d == d }) else { fail("Wellenform A nicht gefunden") }
        guard let g = mix.deck(d).grid else { fail("Deck A ohne Grid") }
        mix.setRange(d, nil)
        mix.core.seek(d, seconds: mix.deck(d).duration / 2)   // Wellenform links und rechts im Track
        u.spin(0.2)
        let r = u.frame(w), dur0 = mix.deck(d).duration
        // Ziehen ohne Taste
        u.drag(from: NSPoint(x: r.minX + r.width * 0.56, y: r.midY), to: NSPoint(x: r.minX + r.width * 0.84, y: r.midY), steps: 8)
        guard let range = mix.range(d) else { fail("EDIT: Ziehen markiert keinen Bereich") }
        let step = mix.prefs.ui.editSnap.beats
        let a = g.beatPosition(at: range.start) / step, b = g.beatPosition(at: range.end) / step
        log(String(format: "edit: bereich %.3f–%.3f s · raster %@", range.start, range.end, mix.prefs.ui.editSnap.label))
        check(abs(a - a.rounded()) < 1e-3 && abs(b - b.rounded()) < 1e-3 || range.end >= dur0 - 1e-3, "EDIT: Bereich nicht auf dem Raster: \(a) – \(b)")
        // Klick daneben hebt den Bereich auf, der nächste setzt eine Marke
        let left = NSPoint(x: r.minX + r.width * 0.3, y: r.midY)
        u.click(at: left)
        check(mix.range(d) == nil, "EDIT: Klick daneben hebt den Bereich nicht auf")
        let segs0 = mix.editSession(d)?.shown.segments.count ?? 0
        u.click(at: left)
        u.spin(WaveMouseView.markDelay + 0.3) { (mix.editSession(d)?.shown.segments.count ?? 0) > segs0 }
        check((mix.editSession(d)?.shown.segments.count ?? 0) == segs0 + 1, "EDIT: Klick setzt keine Schnittmarke")
        // Bereich wieder markieren, Rechtsklick -> entfernen
        mix.setRange(d, range)
        u.spin(0.2)
        let inside = NSPoint(x: r.minX + r.width * 0.7, y: r.midY)
        guard let menu = u.rightClick(at: inside) else { fail("EDIT: kein Rechtsklick-Menü") }
        let item = String(localized: "Bereich entfernen")
        guard let i = menu.items.firstIndex(where: { $0.title == item }) else { fail("EDIT: Menü ohne „\(item)“: \(menu.items.map(\.title))") }
        menu.performActionForItem(at: i)
        u.spin(10) { mix.editSession(d)?.preview != nil && mix.editSession(d)?.rendering == false }
        let dur1 = mix.deck(d).duration
        check(mix.editSession(d)?.preview != nil && abs(dur1 - (dur0 - range.length)) < 0.01,
              "EDIT: Deck spielt die Liste nicht (\(dur0) -> \(dur1), Bereich \(range.length) s)")
        // Tool-Loop 4 Beats aus der Vorschau
        CutJob.lastResult = nil
        mix.exportToolLoop(d, beats: 4)
        u.spin(30) { !CutJob.running && CutJob.lastResult != nil }
        guard let res = CutJob.lastResult else { fail("Tool-Loop: kein Ergebnis") }
        let url = URL(fileURLWithPath: res.track.path)
        check(FileManager.default.fileExists(atPath: url.path), "Tool-Loop: Datei fehlt \(url.path)")
        check(url.path.hasPrefix(CutJob.selfTestDirectory.path), "Tool-Loop: nicht im Test-Ordner: \(url.path)")
        let frames = (try? AVAudioFile(forReading: url)).map { Int($0.length) } ?? -1
        let rate = (try? AVAudioFile(forReading: url))?.processingFormat.sampleRate ?? 0
        check(frames == ToolLoop.frames(beats: 4, bpm: g.bpm, rate: rate), "Tool-Loop: \(frames) Frames, soll \(ToolLoop.frames(beats: 4, bpm: g.bpm, rate: rate))")
        log("edit: tool-loop \(url.lastPathComponent) · \(frames) frames")
        try? FileManager.default.removeItem(at: url)
        // ⌘Z: zurück zum Original
        guard let z = mix.prefs.keys.combo(.undo) else { fail("⌘Z nicht belegt") }
        u.key(z)
        u.spin(5) { mix.editSession(d)?.preview == nil && mix.editSession(d)?.rendering == false }
        check(abs(mix.deck(d).duration - dur0) < 1e-6 && mix.editSession(d)?.preview == nil, "EDIT: ⌘Z stellt das Original nicht her")
        mix.setRange(d, nil)
        mix.setEditing(d, wasEditing)
    }

    /// Deck-Zeile GROOVE an Deck A: Klick ins Raster liest das Muster (Fixture: Kick auf jedem Beat), ▶ MIDI startet
    /// (Quelle im Test versteckt), ■ hält an, ⚄ würfelt neu. Tasten von rechts gesucht (.mid schreibt im Test nur in den
    /// temporären Ordner), die Menüs links werden nie angeklickt
    static func groove(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, g = GrooveCenter.shared
        mix.prefs.ui.deckRows.groove = true
        defer { g.stop(); mix.prefs.ui.deckRows.groove = false; u.spin(0.3) }
        u.spin(2) { u.named("A groove") != nil }
        guard let row = u.named("A groove") else { fail("Groove-Zeile A nicht gefunden") }
        let r = u.frame(row)
        guard r.width >= 360, mix.core.trackAudio(0) != nil else { log("groove: zeile \(Int(r.width)) pt / ohne audio – fall übersprungen"); return }
        // Raster: zwischen Menüs (≤ 190 pt) und Tasten (≤ 160 pt)
        let gx = (r.minX + 190 + r.maxX - 160) / 2
        u.click(at: NSPoint(x: gx, y: r.midY))
        u.spin(3) { g.slots[0].pattern != nil }
        // CI-Runner: synthetische Klicks erreichen die SwiftUI-Gesten und -Tasten der Zeile dort nicht – dann die
        // Aktionen direkt, der Fall prüft dieselben Ergebnisse (Weg steht im Log)
        let clicks = g.slots[0].pattern != nil
        if !clicks {
            log("groove: klick ins raster ohne muster (\(StatusCenter.shared.current?.text ?? "keine Meldung")) – aktionen direkt")
            _ = g.analyze(mix, 0)
            u.spin(3) { g.slots[0].pattern != nil }
        }
        guard let p = g.slots[0].pattern, let clip = g.slots[0].clip else { fail("Klick ins Raster: kein Muster") }
        check(g.running == nil, "Klick ins Raster startet MIDI")
        log("groove muster: \(p.steps) schritte · kick \(p.steps(.kick)) · hats \(p.hatSteps.sorted()) · \(clip.notes.count) noten")
        if UITestFixture.dir != nil {
            check(p.steps(.kick) == Array(stride(from: 0, to: p.steps, by: 4)), "Fixture: Kick nicht auf jedem Beat: \(p.steps(.kick))")
        }
        check(!clip.notes.isEmpty, "keine Noten erzeugt")
        let seed = g.slots[0].seed
        if clicks {
            // ▶ MIDI von rechts suchen
            var playX: CGFloat?
            for x in stride(from: r.maxX - 3, to: r.maxX - 170, by: -4) {
                u.click(at: NSPoint(x: x, y: r.midY))
                if g.running == 0 { playX = x; break }
            }
            guard let px = playX else { fail("▶ MIDI nicht gefunden") }
            check(StatusCenter.shared.current?.text.hasPrefix("Groove → MIDI") == true || StatusCenter.shared.history.contains { $0.text.hasPrefix("Groove → MIDI:") },
                  "keine Statusmeldung „Groove → MIDI …“")
            u.spin(0.5)
            // ■ von rechts (liegt rechts von ▶)
            var stopX: CGFloat?
            for x in stride(from: r.maxX - 3, to: px, by: -4) {
                u.click(at: NSPoint(x: x, y: r.midY))
                if g.running == nil { stopX = x; break }
            }
            guard let sx = stopX else { fail("■ hält MIDI nicht an") }
            check(sx > px + 8, "angehalten nur über ▶ (x \(Int(sx - r.minX)) / \(Int(px - r.minX)))")
            // ⚄ liegt links von ▶: weiter nach links, bis der Seed wechselt (▶ dazwischen wieder aus)
            for x in stride(from: px - 4, to: px - 120, by: -4) where g.slots[0].seed == seed {
                u.click(at: NSPoint(x: x, y: r.midY))
                if g.running != nil { u.click(at: NSPoint(x: x, y: r.midY)) }
            }
        } else {
            g.toggle(mix, 0)
            u.spin(0.5)
            check(g.running == 0, "▶ MIDI startet nicht")
            check(StatusCenter.shared.current?.text.hasPrefix("Groove → MIDI") == true || StatusCenter.shared.history.contains { $0.text.hasPrefix("Groove → MIDI:") },
                  "keine Statusmeldung „Groove → MIDI …“")
            g.stop()
            u.spin(0.2)
            check(g.running == nil, "■ hält MIDI nicht an")
            g.reroll(mix, 0)
            u.spin(0.2)
        }
        check(g.slots[0].seed != seed, "⚄ würfelt nicht neu")
        check(g.running == nil, "MIDI läuft nach ⚄ noch")
    }

    /// DAW-Brücke: Testpaket mit einem Clip der Datei in Deck A an den Empfänger -> Streifen unter der Übersicht, Baum
    /// zeigt DAW, Rechtsklick auf den Decktitel übernimmt das Grid der Warp-Marker, Rückgängig, Abmelden nimmt den Streifen
    static func dawStrip(_ u: UIDriver, _ t: [Track]) {
        let bridge = DAWBridgeModel.shared
        if bridge.port == 0 { bridge.configure(enabled: true, port: 0) }
        check(bridge.port > 0, "DAW-Brücke: Empfänger nicht gestartet")
        guard let path = u.mix.deck(0).track?.path else { fail("Deck A leer") }
        let bpm = 131.0, beat = 60 / bpm, anchor = 0.125
        func send(_ o: [String: Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: o) else { fail("JSON") }
            check(DAWBridgeReceiver.send(d, port: bridge.port), "senden")
        }
        send(["v": 1, "t": "clip", "id": "ui", "track": 2, "trackName": "UI", "name": "Clip", "file": path, "warping": true,
              "markers": [[0, anchor], [32, anchor + 32 * beat]], "loop": [4, 8], "looping": true, "playing": true, "where": "session"])
        send(["v": 1, "t": "song", "seq": 1, "tempo": bpm, "playing": true, "beat": 0, "sig": 4, "clips": ["ui"], "pos": ["ui": [1, 2.0]]])
        u.spin(3) { u.named("A daw") != nil }
        check(bridge.deckClip[0] == "ui", "Clip nicht Deck A zugeordnet")
        guard let strip = u.named("A daw") else { fail("DAW-Streifen unter Deck A fehlt") }
        check(u.frame(strip).height > 4, "DAW-Streifen ohne Höhe")
        check(u.store.tracks(for: .daw).map(\.key) == [DAWBridgeModel.keyPrefix + "ui"], "Quelle DAW ohne den Clip")
        let before = u.mix.deck(0).grid
        guard let hdr = u.named("A header") else { fail("Deck-Kopf A nicht gefunden") }
        let r = u.frame(hdr)
        var found: NSMenu?
        for x in stride(from: r.minX + 2, to: r.minX + min(400, r.width), by: 6) {
            if let m = u.rightClick(at: NSPoint(x: x, y: r.midY)), m.items.contains(where: { $0.title.hasPrefix(String(localized: "Grid des DAW-Clips übernehmen")) }) {
                found = m; break
            }
        }
        guard let menu = found, let i = menu.items.firstIndex(where: { $0.title.hasPrefix(String(localized: "Grid des DAW-Clips übernehmen")) })
        else { fail("Deck-Menü ohne „Grid des DAW-Clips übernehmen“") }
        menu.performActionForItem(at: i)
        u.spin(1) { u.mix.deck(0).grid?.bpm == bpm }
        guard let g = u.mix.deck(0).grid else { fail("Deck A ohne Grid") }
        check(abs(g.bpm - bpm) < 1e-9 && abs(g.anchor - anchor) < 1e-9 && u.mix.deck(0).gridEdited, "Grid nicht aus der DAW: \(g)")
        UndoStack.shared.undo()
        u.mix.pull()
        check(u.mix.deck(0).grid == before, "Rückgängig stellt das Grid nicht her")
        if let out = ProcessInfo.processInfo.environment["MIX741_UITEST_DAWSHOT"] {
            u.spin(1)   // Zeiger der DAW läuft 1 s
            shot(u, out, "daw")
        }
        send(["v": 1, "t": "bye"])
        u.spin(3) { u.named("A daw") == nil }
        check(u.named("A daw") == nil && bridge.clips.isEmpty, "Streifen bleibt nach dem Abmelden")
        log(String(format: "daw: streifen %.0f × %.0f pt, grid %.2f bpm übernommen + rückgängig", u.frame(strip).width, u.frame(strip).height, bpm))
    }

    /// Master-FX: belegtes Tastenkürzel schaltet den Master-Bus an und aus; Kette im Master-Bus lädt, Mixer zeigt sie
    static func masterFX(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        let keys = mix.prefs.keys
        guard let combo = [KeyCombo("f", [.control, .option]), KeyCombo("g", [.control, .option])].first(where: { keys.action(for: $0) == nil })
        else { fail("keine freie Taste für Master-FX") }
        mix.prefs.keys.set(.masterFX, combo)
        defer { mix.prefs.keys = keys }
        mix.prefs.ui.showMixer = true
        u.window.makeFirstResponder(nil)
        u.spin(0.3)
        let on0 = mix.masterFX.on
        u.key(combo)
        u.spin(1) { mix.masterFX.on != on0 }
        check(mix.masterFX.on != on0, "\(combo.symbols): Master-FX schaltet nicht")
        u.key(combo)
        u.spin(1) { mix.masterFX.on == on0 }
        check(mix.masterFX.on == on0, "\(combo.symbols): Master-FX schaltet nicht zurück")
        mix.addSlot(MixController.masterBus, "aufx:lpas:appl")
        u.spin(10) { mix.core.pluginInstance(MixController.masterBus, slot: 0) != nil }
        check(mix.slots(MixController.masterBus).map(\.id) == ["aufx:lpas:appl"], "Master-Rack: \(mix.slots(MixController.masterBus).map(\.id))")
        check(mix.core.pluginInstance(MixController.masterBus, slot: 0) != nil, "Master-Rack: AULowpass lädt nicht")
        mix.removeSlot(MixController.masterBus, slot: 0)
        mix.prefs.ui.showMixer = false
        u.spin(0.3)
        check(mix.slots(MixController.masterBus).isEmpty, "Master-Rack nicht leer")
    }

    /// Doppelklick auf Regler und Fader = Standardwert: GAIN-Knopf im Mixer (Kanalzug C·A·B·D: der erste ist Deck C),
    /// Crossfader (NSSlider) und Kanalfader; Ziehen bleibt davon unberührt
    static func doubleClickReset(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        let showMixer = mix.prefs.ui.showMixer, mode = mix.mixerMode
        mix.prefs.ui.showMixer = true; mix.mixerMode = .internalMixer
        u.spin(0.4)
        defer { mix.prefs.ui.showMixer = showMixer; mix.mixerMode = mode }
        guard let gain = u.named("dbl GAIN") else { fail("GAIN-Knopf nicht gefunden") }
        let f = u.frame(gain), c = NSPoint(x: f.midX, y: f.midY)
        func gains() -> [Double] { (0..<4).map { mix.deck($0).gainDb } }
        // synthetische Drags erreichen SwiftUI-DragGestures nicht (nur AppKit-Handler wie die Wellenform), deshalb Werte setzen
        for d in 0..<4 { mix.updateDeck(d) { $0.gainDb = 6 } }
        u.doubleClick(at: c)
        u.spin(0.2)
        let after = gains()
        check(after.filter { $0 == 0 }.count == 1 && after.filter { $0 == 6 }.count == 3, "GAIN nach Doppelklick: \(after)")
        u.doubleClick(at: c)   // noch einmal: bleibt 0, kein zweiter Kanal
        u.spin(0.2)
        check(gains() == after, "zweiter Doppelklick: \(gains())")
        // Crossfader (NSSlider)
        mix.setCrossfader(0.7)
        guard let xf = u.named("dbl XFADE") else { fail("Crossfader nicht gefunden") }
        u.doubleClick(at: NSPoint(x: u.frame(xf).midX, y: u.frame(xf).midY))
        u.spin(0.2)
        check(mix.crossfader == 0, "Crossfader nach Doppelklick: \(mix.crossfader)")
        log("doppelklick: GAIN 6 → \(after), Crossfader 0.7 → \(mix.crossfader)")
    }

    /// Browser übereinander: Kopf eines Bereichs (Titel, Suche, Rollen, Tags) als Spalte links neben der Liste, die
    /// Liste reicht bis unter die Favoritenleiste
    static func stackedSide(_ u: UIDriver, _ t: [Track]) {
        let layout = u.mix.prefs.ui.browserLayout
        defer { u.mix.prefs.ui.browserLayout = layout; u.spin(0.3) }
        check(u.named("pane side A") == nil, "Seitenspalte schon nebeneinander")
        let m = u.browser.paneA
        u.mix.pull()
        let before = m.paneHeight - m.favoritesHeight - m.tableHeight   // Kopf nebeneinander: zwei Zeilen
        u.mix.prefs.ui.browserLayout = .stacked
        u.spin(2) { u.named("pane side B") != nil }
        u.spin(0.3)
        guard let a = u.named("pane side A"), let b = u.named("pane side B") else { fail("Seitenspalte fehlt") }
        let fa = u.frame(a), fb = u.frame(b)
        check(fa.minY > fb.maxY - 1, "A nicht über B: \(fa) \(fb)")
        check(abs(fa.width - PaneHeader.sideWidth) < 1, "Spaltenbreite \(fa.width)")
        // der Kopf kostet keine Höhe mehr: Tabelle = Bereich − Favoritenleiste (bis auf Ränder)
        let after = m.paneHeight - m.favoritesHeight - m.tableHeight
        check(after < 12 && before - after > 30,
              "Tabelle \(m.tableHeight) pt von \(m.paneHeight) − Favoriten \(m.favoritesHeight): Rest \(after) (nebeneinander \(before))")
        guard let sf = u.searchField(pane: 0) else { fail("Suchfeld fehlt") }
        check(fa.contains(u.frame(sf)), "Suchfeld nicht in der Spalte: \(u.frame(sf))")
        // Suche aus der Spalte heraus wirkt auf die Liste
        let search = m.search, rows = m.shown.count
        u.click(at: u.center(sf))
        u.spin(0.3)
        check(u.window.firstResponder is NSText, "Klick ins Suchfeld der Spalte: kein Texteditor")
        u.type("zzqxv-nichts")
        u.key(KeyCombo("return", []))
        u.spin(2) { m.search == "zzqxv-nichts" }
        check(m.search == "zzqxv-nichts", "Suche aus der Spalte kommt nicht an: „\(m.search)“")
        u.spin(2) { m.shown.isEmpty }
        check(m.shown.isEmpty, "Liste nicht gefiltert: \(m.shown.count) von \(rows)")
        m.search = search
        u.spin(2) { m.shown.count == rows }
        if let out = ProcessInfo.processInfo.environment["MIX741_UITEST_STACKSHOT"] { shot(u, out, "gestapelt") }
        log(String(format: "gestapelt: spalte %.0f × %.0f pt, tabelle %.0f von %.0f pt, kopf %.1f → %.1f pt", fa.width, fa.height, m.tableHeight, m.paneHeight, before, after))
    }

    /// Bild des Fensterinhalts (zum Ansehen), 2×
    static func shot(_ u: UIDriver, _ out: String, _ what: String) {
        guard let v = u.window.contentView?.superview, let layer = v.layer else { return }
        let w = Int(v.bounds.width * 2), h = Int(v.bounds.height * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: 2, y: 2)
        if v.isFlipped { ctx.translateBy(x: 0, y: v.bounds.height); ctx.scaleBy(x: 1, y: -1) }
        layer.render(in: ctx)
        if let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
            log("\(what): bild \(out)")
        }
    }

}

extension UISelfTest {
    /// ◆ UNGESPIELT im Kopf von Bereich A: Klick blendet die gespielten Tracks aus (Zeilen sinken um die gespielten,
    /// Anzahl „ausgeblendet“ im Kopf), History und Preparation bleiben; zweiter Klick zeigt sie wieder
    static func unplayed(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, pane = u.browser.paneA
        guard let history = u.browser.history else { fail("UNGESPIELT: keine History") }
        let played0 = history.played, hide0 = mix.prefs.ui.hidePlayedTracks, source0 = pane.source
        defer { history.setPlayed(played0); mix.prefs.ui.hidePlayedTracks = hide0; pane.source = source0; u.spin(0.5) }
        mix.prefs.ui.hidePlayedTracks = false
        pane.source = .collection
        u.spin(5) { !pane.listPending && !pane.shown.isEmpty }
        u.spin(0.3)
        let n0 = pane.shown.count
        check(n0 >= 3, "UNGESPIELT: Bereich A zeigt \(n0) Tracks")
        history.setPlayed(played0.union(pane.shown.prefix(2).map(\.key)))
        let played = history.played
        let expected = pane.shown.filter { played.contains($0.key) }.count
        guard let marker = u.views.compactMap({ $0 as? UITestMark.V }).filter({ $0.name == "unplayed" })
            .min(by: { u.frame($0).minX < u.frame($1).minX }) else { fail("Knopf UNGESPIELT nicht gefunden") }
        let r = u.frame(marker), p = NSPoint(x: r.midX, y: r.midY)
        check(r.width > 10 && u.window.contentView?.bounds.contains(p) == true, "UNGESPIELT liegt außerhalb: \(r)")
        // Klick direkt an die getroffene Hosting-View (NSWindow.sendEvent kommt dort im Test nicht immer an)
        let root = u.window.contentView?.superview ?? u.host
        guard let hit = root.hitTest(root.convert(p, from: nil)) else { fail("UNGESPIELT: nichts unter dem Knopf") }
        func click() {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: u.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { fail("kein Mausereignis") }
                if type == .leftMouseDown { hit.mouseDown(with: e) } else { hit.mouseUp(with: e) }
            }
        }
        func tableRows() -> Int? {
            u.views.compactMap { $0 as? TrackHeaderView }.filter { u.frame($0).minX < u.window.frame.width / 2 }
                .compactMap { $0.tableView?.numberOfRows }.first
        }
        // CI-Runner: der synthetische Klick erreicht den SwiftUI-Knopf dort nicht – dann die Einstellung direkt (steht im Log)
        func press() {
            let want = !mix.prefs.ui.hidePlayedTracks
            click()
            u.spin(1) { mix.prefs.ui.hidePlayedTracks == want }
            if mix.prefs.ui.hidePlayedTracks != want { log("ungespielt: klick auf den knopf kommt nicht an – schalte direkt"); mix.prefs.ui.hidePlayedTracks = want }
        }
        press()
        u.spin(5) { mix.prefs.ui.hidePlayedTracks && !pane.listPending && pane.shown.count == n0 - expected && tableRows() == n0 - expected }
        check(mix.prefs.ui.hidePlayedTracks, "Klick auf UNGESPIELT schaltet nicht")
        check(pane.shown.count == n0 - expected, "UNGESPIELT: \(pane.shown.count) Zeilen, soll \(n0) − \(expected)")
        check(tableRows() == n0 - expected, "UNGESPIELT: Tabelle hat \(tableRows() ?? -1) Zeilen, soll \(n0 - expected)")
        check(pane.hiddenCount == expected, "UNGESPIELT: \(pane.hiddenCount) ausgeblendet, soll \(expected)")
        check(!pane.shown.contains { played.contains($0.key) }, "UNGESPIELT: gespielter Track noch in der Liste")
        check(BrowserPaneModel.hiddenKeys(source: .historyLive, played: played, hidePlayed: true) == nil
              && BrowserPaneModel.hiddenKeys(source: .preparation, played: played, hidePlayed: true) == nil, "UNGESPIELT wirkt auf History / Preparation")
        press()
        u.spin(5) { !mix.prefs.ui.hidePlayedTracks && !pane.listPending && pane.shown.count == n0 }
        check(!mix.prefs.ui.hidePlayedTracks && pane.shown.count == n0, "zweiter Klick: \(pane.shown.count) Zeilen, soll \(n0)")
        log("ungespielt: \(n0) -> \(n0 - expected) zeilen (\(expected) gespielt) -> \(pane.shown.count)")
    }
}

extension UISelfTest {
    /// Profil „Vorbereiten“ an Deck A mit einer eigenen WAV (16 Bit, Spitze 0.5, 120 BPM, im Temp-Ordner): Werkzeugzeile
    /// da, Deck im EDIT-Modus, Klick auf +3 -> Gain +3 dB, Klick auf RENDER -> `[amp +3].wav` im Test-Ordner mit
    /// Spitze × 1,41. MIX741_UITEST_PREPSHOT=<png>: Bild des Fensters. Danach Ansicht und Deck A wie vorher
    /// AUDIO-EDIT: Import-Lauf über drei Tracks, ein Deck, WEITER lädt den nächsten, ERLEDIGT markiert, Verlassen stellt die Ansicht her
    static func audioEdit(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, m = AudioEditMode.shared, d = AudioEditMode.deck
        if mix.deck(d).playing { mix.togglePlay(d) }
        let before = LayoutProfile(name: "", ui: mix.prefs.ui, maximized: u.browser.maximized)
        let tracks = Array(t.prefix(3))
        check(tracks.count >= 2, "audio-edit: weniger als zwei Tracks")
        m.importRun(tracks, title: "UITest")
        u.spin(20) { m.active && mix.deck(d).track != nil && !mix.deck(d).loading }
        check(m.active, "audio-edit: Modus nicht an")
        check(!m.list.isEmpty, "audio-edit: Arbeitsliste leer")
        check(mix.prefs.ui.deckCount == 1, "audio-edit: nicht ein Deck (\(mix.prefs.ui.deckCount))")
        check(mix.deck(d).track?.key == m.list[0].key, "audio-edit: Deck A lädt nicht den ersten Track")
        if m.list.count >= 2 {
            let second = m.list[1].key
            m.next()
            u.spin(20) { mix.deck(d).track?.key == second && !mix.deck(d).loading }
            check(mix.deck(d).track?.key == second, "audio-edit: WEITER lädt nicht den nächsten Track")
            let first = m.list[1].key
            m.done()
            check(m.store.isReviewed(first), "audio-edit: ERLEDIGT markiert nicht")
        }
        let n = m.list.count
        m.leave()
        check(!m.active, "audio-edit: nicht verlassen")
        let after = LayoutProfile(name: "", ui: mix.prefs.ui, maximized: u.browser.maximized)
        check(after.sameView(as: before), "audio-edit: Ansicht nach dem Verlassen anders")
        m.store.reset()
        log("audio-edit: \(n) Tracks · WEITER lädt · ERLEDIGT · Verlassen stellt die Ansicht her")
    }

    /// Editor im AUDIO-EDIT-Modus: Zoom bis auf die Samples, Auswahl, Rückwärts / Löschen / Kopieren und Einfügen (je mit
    /// Rückgängig), Marken, Schritte, Verlassen. MIX741_UITEST_EDITSHOT=<png>: Bild des Fensters (Auswahl im Sample-Zoom)
    static func audioEditor(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, m = AudioEditMode.shared, d = AudioEditMode.deck
        if mix.deck(d).playing { mix.togglePlay(d) }
        let wasEditing = mix.editing(d)
        let tracks = Array(t.prefix(2))
        check(tracks.count >= 1, "audio-editor: keine Tracks")
        UndoStack.shared.clearAll()
        m.importRun(tracks, title: "UITest")
        u.spin(20) { m.active && mix.deck(d).track != nil && !mix.deck(d).loading && mix.editSession(d) != nil }
        check(m.active && mix.editSession(d) != nil, "audio-editor: Editor nicht bereit")
        u.spin(5) { m.secPerPoint > 0 }
        check(m.secPerPoint > 0 && m.viewWidth > 0, "audio-editor: keine Ansicht")
        let dur = m.duration
        check(abs(dur - mix.deck(d).duration) < 1e-6, "audio-editor: Dauer des Editors weicht ab")
        check(m.snap == mix.prefs.ui.audioEditGrid, "audio-editor: Raster nicht wie eingestellt")
        if m.snap { m.snapToggle() }   // Sample-genaue Auswahl für die folgenden Schritte
        // Zoom bis auf die Samples und zurück auf die ganze Datei
        for _ in 0..<60 where m.secPerPoint * m.rate > 1 { m.zoomKey(AudioEditView.zoomStep) }
        check(m.secPerPoint * m.rate <= 1, "audio-editor: Zoom erreicht die Sample-Ebene nicht")
        m.fitView()
        check(abs(m.secPerPoint - dur / m.viewWidth) < 1e-9, "audio-editor: ALLES passt nicht")
        // Auswahl (Sekunden auf Samples gerastet), rückwärts, Rückgängig
        let a = 1.0, b = 2.0
        m.setSelection(TrackRange(a, b))
        check(m.selection == TrackRange(a, b), "audio-editor: Auswahl weicht ab")
        m.reverse()
        u.spin(20) { mix.editSession(d)?.rendering == false }
        check(m.shown?.segments.contains { $0.isReversed } == true, "audio-editor: rückwärts fehlt")
        check(abs(m.duration - dur) < 1e-6, "audio-editor: Länge ändert sich beim Rückwärts")
        UndoStack.shared.perform(redo: false)
        u.spin(20) { mix.editSession(d)?.rendering == false }
        check(m.shown?.isPlain == true, "audio-editor: Rückgängig stellt das Original nicht her")
        // Löschen, Kopieren, Einfügen
        m.setSelection(TrackRange(a, b))
        m.delete()
        u.spin(20) { mix.editSession(d)?.rendering == false }
        check(abs(m.duration - (dur - 1)) < 1e-6, "audio-editor: Löschen ändert die Länge nicht")
        m.setSelection(TrackRange(0, 0.5))
        check(m.copy(), "audio-editor: Kopieren ohne Ergebnis (Auswahl \(String(describing: m.selection)), Track \(m.editTrack?.key ?? "-"), Stücke \(m.shown?.segments.count ?? -1), Dauer \(m.duration))")
        m.setCursor(3)
        m.paste()
        u.spin(20) { mix.editSession(d)?.rendering == false }
        check(abs(m.duration - (dur - 0.5)) < 1e-6, "audio-editor: Einfügen ändert die Länge nicht")
        // dritter Schritt (Rückgängig oben hat den ersten zurückgenommen, Neues löscht Wiederherstellen)
        m.setSelection(TrackRange(0, 1))
        m.reverse()
        u.spin(20) { mix.editSession(d)?.rendering == false }
        // Marken am Cursor und am Bereich, Name über den Dialog nicht (der hält den Test an)
        m.setCursor(2)
        m.addMarker(range: false)
        m.setSelection(TrackRange(0, 1))
        m.addMarker(range: true)
        check(m.marks.count == 2, "audio-editor: Marken \(m.marks.count) statt 2")
        check(m.marks.contains { $0.end != nil }, "audio-editor: Bereichsmarke fehlt")
        // Schritte: Rückgängig springt zum ersten Schritt zurück
        let steps = UndoStack.shared.timeline.count
        check(steps >= 3, "audio-editor: Schritte \(steps) statt mindestens 3")
        UndoStack.shared.jump(to: 0)
        u.spin(20) { mix.editSession(d)?.rendering == false }
        check(UndoStack.shared.timeline.filter { !$0.undone }.count == 1, "audio-editor: Sprung zum Schritt")
        UndoStack.shared.jump(to: steps - 1)
        u.spin(20) { mix.editSession(d)?.rendering == false }
        check(UndoStack.shared.timeline.filter { !$0.undone }.count == steps, "audio-editor: Vorwärts-Sprung")
        // Bild: Auswahl von 10 ms, im Sample-Zoom
        m.setSelection(TrackRange(1, 1.01))
        m.zoomToSelection()
        u.spin(2)
        if let out = ProcessInfo.processInfo.environment["MIX741_UITEST_EDITSHOT"] { shot(u, out, "audio-editor") }
        // Verlassen: Ansicht und EDIT von Deck A wie vorher
        m.marks.forEach { m.deleteMarker($0.id) }
        UndoStack.shared.clearAll()
        m.leave()
        check(!m.active, "audio-editor: nicht verlassen")
        check(mix.editing(d) == wasEditing, "audio-editor: EDIT von Deck A nicht wiederhergestellt")
        m.store.reset()
        log("audio-editor: Zoom bis Sample · Auswahl · rückwärts · Löschen · Kopieren/Einfügen · Marken · Schritte · Verlassen")
    }

    static func prepareMode(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, d = 0
        if mix.deck(d).playing { mix.togglePlay(d) }
        let savedUI = mix.prefs.ui, savedBig = u.browser.maximized, before = mix.deck(d).track, wasEditing = mix.editing(d)
        UITestFrames.on = true
        // Quelle: 20 s Kick, Spitze genau 0.5
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-uitest-prep-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("prep.wav")
        let rate = 44_100.0, n = Int(rate * 20)
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let f = try AVAudioFile(forWriting: url, settings: settings)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let kick = (0..<n).map { i -> Double in
                let k = (Double(i) / rate).truncatingRemainder(dividingBy: 0.5)
                return sin(2 * .pi * (50 + 120 * exp(-k * 40)) * k) * exp(-k * 12)
            }
            let scale = 0.5 / (kick.map(abs).max() ?? 1)
            for i in 0..<n {
                let v = Float((kick[i] * scale * 32_768).rounded() / 32_768)   // 16 Bit genau, Spitze 16384 = 0.5
                buf.floatChannelData![0][i] = v
                buf.floatChannelData![1][i] = v
            }
            try f.write(from: buf)
        } catch { fail("Vorbereiten: Test-WAV nicht geschrieben: \(error)") }
        defer {
            try? FileManager.default.removeItem(at: dir)
            UITestFrames.on = false
        }
        var track = Track(key: url.path, path: url.path)
        track.title = "Prepare Fixture"
        track.bpm = 120
        track.duration = 20
        track.cues = [Cue(name: "AutoGrid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
        _ = mix.load(track, deck: d, force: true)
        u.spin(20) { mix.core.trackAudio(d) != nil && mix.deck(d).track?.key == track.key }
        check(mix.core.trackAudio(d) != nil, "Vorbereiten: Test-WAV lädt nicht")
        // Profil wie aus dem Menü
        let p = mix.prefs.ui.layoutProfiles.first { $0.id == LayoutProfile.prepareID } ?? LayoutProfile.prepare(from: mix.prefs.ui)
        LayoutProfiles.apply(p, mix: mix, browser: u.browser)
        u.spin(5) { u.named("A prepare") != nil && mix.editing(d) && mix.editSession(d) != nil && mix.prepState(d).peak != nil }
        guard let row = u.named("A prepare") else { fail("Vorbereiten: Werkzeugzeile A fehlt") }
        check(mix.editing(d) && mix.editSession(d) != nil, "Vorbereiten: Deck A nicht im EDIT-Modus")
        check(u.named("A transport") == nil && u.named("A loop") == nil, "Vorbereiten: Transport- / Loop-Zeile sichtbar")
        // Deck-Puffer in der Rate des Geräts: Spitze bis ~0.2 dB neben der der Datei (RENDER misst die Ausgabe genau)
        check(abs((mix.prepState(d).peak ?? 0) - 0.5) < 0.015, "Vorbereiten: Spitze \(mix.prepState(d).peak ?? -1) statt 0.5")
        // Taste klicken; kommt der Klick nicht an, das Tastenkürzel derselben Aktion (KeyMonitor), kommt auch das nicht an
        // (synthetische Ereignisse erreichen SwiftUI / die Monitore nicht, wie „groove“ auf main), die Aktion direkt.
        // Der Weg steht im Log
        var via: [String] = []
        func press(_ id: String, key: ShortcutID, times: Int = 1, until done: () -> Bool, direct: () -> Void) {
            let marks = u.views.compactMap { $0 as? UITestFrames.Marker }.filter { $0.id == "\(d).\(id)" && $0.window === u.window }
            guard let m = marks.first(where: { u.frame(row).contains(u.center($0)) }) else {
                fail("Vorbereiten: Taste \(id) nicht in der Zeile (\(marks.map { u.frame($0) }))")
            }
            u.click(at: u.center(m))
            u.spin(1, until: done)
            guard !done() else { via.append("\(id): klick"); return }
            let keys = mix.prefs.keys
            guard let combo = [KeyCombo("y", [.control, .option, .shift]), KeyCombo("u", [.control, .option, .shift])]
                .first(where: { keys.action(for: $0) == nil || keys.action(for: $0) == key }) else { fail("Vorbereiten: keine freie Taste") }
            mix.prefs.keys.set(key, combo)
            u.window.makeFirstResponder(nil)
            for _ in 0..<times { u.key(combo); u.spin(0.1) }
            mix.prefs.keys = keys
            u.spin(1, until: done)
            guard !done() else { via.append("\(id): taste \(combo.symbols)"); return }
            via.append("\(id): direkt (klick und taste nicht zugestellt)")
            direct()
            u.spin(1, until: done)
        }
        u.spin(0.3)
        press("amp.3", key: .prepAmpUp, times: 3, until: { mix.prepState(d).gainDb == 3 }, direct: { mix.prepareAmp(d, add: 3) })
        check(mix.prepState(d).gainDb == 3 && !mix.prepState(d).limited, "Vorbereiten: +3 setzt \(mix.prepState(d).gainDb) dB")
        log(String(format: "vorbereiten: zeile %.0f × %.0f pt · gain %@ dB · headroom %.1f dB", u.frame(row).width, u.frame(row).height,
                   Amplify.label(mix.prepState(d).gainDb), mix.prepState(d).headroomLeft ?? .nan))
        if let out = ProcessInfo.processInfo.environment["MIX741_UITEST_PREPSHOT"], let v = u.window.contentView?.superview, let layer = v.layer {
            u.spin(1)   // Zeile und Wellenform nachgezogen
            let w = Int(v.bounds.width * 2), h = Int(v.bounds.height * 2)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: 2, y: 2)
                if v.isFlipped { ctx.translateBy(x: 0, y: v.bounds.height); ctx.scaleBy(x: 1, y: -1) }
                layer.render(in: ctx)
                if let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    log("vorbereiten: bild \(out)")
                }
            }
        }
        // Reste eines abgebrochenen Laufs im Test-Ordner
        let cutDir = CutJob.selfTestDirectory
        for f in (try? FileManager.default.contentsOfDirectory(atPath: cutDir.path)) ?? [] where f.hasPrefix("prep [amp") {
            try? FileManager.default.removeItem(at: cutDir.appendingPathComponent(f))
        }
        CutJob.lastTracks = []
        press("render", key: .prepRender, until: { CutJob.running || !CutJob.lastTracks.isEmpty }, direct: { mix.prepareRender(d) })
        u.spin(30) { !CutJob.running && !CutJob.lastTracks.isEmpty }
        log("vorbereiten: eingabe " + via.joined(separator: " · "))
        guard let res = CutJob.lastTracks.first else { fail("Vorbereiten: RENDER ohne Ergebnis (\(StatusCenter.shared.current?.text ?? "-"))") }
        let file = URL(fileURLWithPath: res.path)
        defer { try? FileManager.default.removeItem(at: file) }
        check(file.path.hasPrefix(CutJob.selfTestDirectory.path), "Vorbereiten: nicht im Test-Ordner: \(file.path)")
        check(file.lastPathComponent == "prep [amp +3].wav", "Vorbereiten: Dateiname \(file.lastPathComponent)")
        guard let s = try? AudioCutWriter.source(url: file, deck: nil) else { fail("Vorbereiten: Ergebnis nicht lesbar") }
        let peak = AudioCutWriter.peak(s.channels, frames: s.frames)
        check(s.frames == n && abs(peak / 0.5 - 1.4125) < 1e-3, "Vorbereiten: \(s.frames) Frames, Spitze \(peak) (soll \(0.5 * 1.4125))")
        check(abs((CutJob.lastGain ?? 0) - 3) < 1e-6 && res.title == "Prepare Fixture [amp +3]", "Vorbereiten: Gain \(CutJob.lastGain ?? -1), Titel \(res.title)")
        log(String(format: "vorbereiten: %@ · %d frames · spitze %.4f -> %.4f (× %.4f)", file.lastPathComponent, s.frames, 0.5, peak, peak / 0.5))
        // zurück
        mix.prefs.ui = savedUI
        u.browser.maximized = savedBig
        u.spin(1) { u.named("A prepare") == nil }
        check(mix.editing(d) == wasEditing, "Vorbereiten: EDIT bleibt nach dem Profilwechsel an")
        if let b = before { _ = mix.load(b, deck: d, force: true); u.spin(20) { mix.core.trackAudio(d) != nil && mix.deck(d).track?.key == b.key } }
    }
}

extension UISelfTest {
    /// Rechtsklick auf PLAYLISTS im Baum von Bereich A → „Neue Smartlist …“ → Editor (Sheet): Feld über das Menü
    /// Genre, Wert „Techno“ getippt → Treffer > 0 → ⏎ speichert → Eintrag im Baum, Bereich A zeigt die Treffer;
    /// Track auf eine eigene Playlist im Baum fallen lassen, ⌫ in der Liste nimmt ihn wieder heraus.
    /// Eigener Baum nur im Temp-Ordner des Selbsttests; ohne Techno in der Collection bekommt ein Track das Genre
    /// (nur im Speicher)
    static func playlistTree(_ u: UIDriver, _ t: [Track]) {
        let pane = u.browser.paneA, store = u.store
        let source = pane.source, showTree = pane.showTree, hide = u.mix.prefs.ui.hideTreeWithDecks
        pane.showTree = true
        u.mix.prefs.ui.hideTreeWithDecks = false
        var edited: String?
        if !store.tracks.contains(where: { SmartRules.contains(Track.fold($0.genre), Track.fold("Techno")) }) {
            edited = t[2].key
            store.applyEdits([t[2].key: [.genre: "Techno"]], writeBack: false)
        }
        defer {
            if let k = edited { store.revertEdits([k]) }
            pane.source = source
            pane.showTree = showTree
            u.mix.prefs.ui.hideTreeWithDecks = hide
        }
        let before = store.playlists
        u.spin(0.5)
        // Baum von Bereich A: SwiftUI-Liste links (keine Track-Tabelle)
        guard let tree = u.views.compactMap({ $0 as? NSTableView }).filter({ !($0 is TrackNSTable) && $0.numberOfRows > 3 })
            .min(by: { u.frame($0).minX < u.frame($1).minX }) else { fail("Baum von Bereich A nicht gefunden") }
        let rows0 = tree.numberOfRows
        let item = String(localized: "Neue Smartlist …")
        var menu: NSMenu?
        for r in 0..<tree.numberOfRows {
            tree.scrollRowToVisible(r)
            u.spin(0.02)
            let rect = tree.convert(tree.rect(ofRow: r), to: nil)
            if let m = u.rightClick(at: NSPoint(x: rect.minX + 60, y: rect.midY)), m.items.contains(where: { $0.title == item }) { menu = m; break }
        }
        guard let menu, let i = menu.items.firstIndex(where: { $0.title == item }) else { fail("Rechtsklick im Baum: kein „\(item)“") }
        log("menü an PLAYLISTS: " + menu.items.map(\.title).joined(separator: " · "))
        menu.performActionForItem(at: i)
        u.spin(5) { u.window.attachedSheet != nil && SmartlistDraft.current != nil }
        guard let sheet = u.window.attachedSheet, let draft = SmartlistDraft.current else { fail("Smartlist-Editor öffnet nicht") }
        u.spin(0.5)
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let views = all(sheet.contentView?.superview ?? sheet.contentView!)
        // Feld-Menü der ersten Zeile: oberstes, linkes Menü mit „Genre“
        let genre = SmartLabels.field(.genre), artist = SmartLabels.field(.artist)
        guard let popup = views.compactMap({ $0 as? NSPopUpButton }).filter({ $0.itemTitles.contains(genre) })
            .min(by: { a, b in sheet.contentView!.convert(a.bounds, from: a).minX < sheet.contentView!.convert(b.bounds, from: b).minX }) else { fail("Feld-Menü nicht gefunden") }
        for f in [artist, genre] {
            popup.selectItem(withTitle: f)
            _ = popup.sendAction(popup.action, to: popup.target)
            u.spin(0.2)
        }
        check(draft.rules.rules.first?.field == .genre, "Feld-Menü: \(draft.rules.rules.first.map { "\($0.field)" } ?? "-") statt genre")
        check(draft.rules.rules.first?.op == .contains, "Operator nicht „enthält“")
        // Wert tippen: Feld „WERT“ (Combo), Tasten an das Sheet
        guard let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && $0.placeholderString == String(localized: "WERT") }) else { fail("Wertfeld nicht gefunden") }
        sheet.makeFirstResponder(field)
        u.spin(0.1)
        func key(_ chars: String, _ code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: sheet.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code)!
                sheet.sendEvent(e)
            }
            u.spin(0.02)
        }
        for ch in "Techno" { key(String(ch), 0) }
        u.spin(3) { draft.rules.rules.first?.value == "Techno" && draft.countIsCurrent }
        check(draft.rules.rules.first?.value == "Techno", "Wert: „\(draft.rules.rules.first?.value ?? "")“ statt „Techno“ (Feld „\(field.stringValue)“)")
        guard draft.countIsCurrent, let n = draft.count, n > 0, n < store.tracks.count else { fail("Treffer: \(draft.count.map(String.init) ?? "keine Zahl") von \(store.tracks.count)") }
        let want = store.tracks.filter { SmartRules.contains(Track.fold($0.genre), Track.fold("Techno")) }.count
        check(n == want, "Treffer im Editor \(n), Genre enthält „Techno“ in der Collection \(want)")
        log("editor: genre enthält „Techno“ -> \(n) treffer")
        // ⏎ = SPEICHERN (Standard-Knopf), erst Feld verlassen
        sheet.makeFirstResponder(nil)
        let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                   isARepeat: false, keyCode: 36)!
        if !sheet.performKeyEquivalent(with: ret) { sheet.sendEvent(ret) }
        u.spin(5) { u.window.attachedSheet == nil }
        check(u.window.attachedSheet == nil, "⏎ speichert nicht (Editor bleibt offen)")
        let added = store.playlists.all.filter { b in !before.contains(b.id) }
        guard added.count == 1, let sl = added.first, sl.kind == .smartlist,
              sl.rules.rules.first.map({ $0.field == .genre && $0.op == .contains && $0.value == "Techno" }) == true else {
            fail("gespeichert: \(added.map { "\($0.kind) \($0.name)" })")
        }
        u.spin(3) { tree.numberOfRows == rows0 + 1 }
        check(tree.numberOfRows == rows0 + 1, "Baum: \(tree.numberOfRows) Zeilen statt \(rows0 + 1)")
        check(pane.source == .own(OwnRef(sl)), "Bereich A zeigt nicht die neue Smartlist")
        u.spin(3) { pane.shown.count == n }
        check(pane.shown.count == n, "Bereich A: \(pane.shown.count) Zeilen statt \(n)")
        log("baum: \(rows0) -> \(tree.numberOfRows) zeilen · „\(sl.name)“ · bereich A \(pane.shown.count) tracks")
        // Track auf eine eigene Playlist im Baum ziehen (letzte eigene Zeile = neueste Playlist), dann ⌫ in der Liste
        let pl = store.addOwn(.playlist, into: nil, name: "UI Playlist")
        u.spin(3) { tree.numberOfRows == rows0 + 2 }
        let targets = u.views.filter { ($0 as? UITestNamed)?.name == "tree drop" && u.frame($0).minX < u.window.frame.width / 2 && $0.window === u.window }
        guard let last = targets.min(by: { u.frame($0).minY < u.frame($1).minY }) else { fail("keine Ablage-Ansichten im Baum") }
        check(u.drop(string: TrackDrag.prefix + t[0].key, at: u.center(last)), "Drop auf die Playlist nicht angenommen")
        u.spin(3) { store.playlists.item(pl.id)?.tracks == [t[0].key] }
        check(store.playlists.item(pl.id)?.tracks == [t[0].key], "Playlist nach dem Drop: \(store.playlists.item(pl.id)?.tracks.count ?? -1) Tracks")
        pane.source = .own(OwnRef(pl))
        u.spin(3) { pane.shown.map(\.key) == [t[0].key] }
        pane.selection = [t[0].key]
        guard let table = u.views.compactMap({ $0 as? TrackNSTable }).min(by: { u.frame($0).minX < u.frame($1).minX }) else { fail("Track-Tabelle A fehlt") }
        u.window.makeFirstResponder(table)
        let del = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: u.window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                   isARepeat: false, keyCode: 51)!
        u.window.sendEvent(del)
        u.spin(1) { store.playlists.item(pl.id)?.tracks.isEmpty == true }
        check(store.playlists.item(pl.id)?.tracks.isEmpty == true, "⌫ entfernt den Track nicht aus der Playlist")
        // Eintrag (wie aus dem Baum gezogen) auf einen eigenen Ordner: hinein
        let folder = store.addOwn(.folder, into: nil, name: "UI Ordner")
        u.spin(3) { tree.numberOfRows == rows0 + 3 }
        let targets2 = u.views.filter { ($0 as? UITestNamed)?.name == "tree drop" && u.frame($0).minX < u.window.frame.width / 2 && $0.window === u.window }
        guard let fv = targets2.min(by: { u.frame($0).minY < u.frame($1).minY }) else { fail("Ordner-Zeile fehlt") }
        check(u.drop(string: TreeDrag.prefix + pl.id.uuidString, at: u.center(fv)), "Drop eines Eintrags auf den Ordner nicht angenommen")
        u.spin(1) { store.playlists.parent(of: pl.id) == .some(folder.id) }
        check(store.playlists.parent(of: pl.id) == .some(folder.id), "Playlist nicht im Ordner")
        log("drop auf playlist + ⌫ in der liste + eintrag in ordner ok")
        // PREPARATION: Track auf die Zeile ziehen, sie hängt ihn an (Zone „tree drop prep“)
        guard let prep = u.views.first(where: { ($0 as? UITestNamed)?.name == "tree drop prep" && $0.window === u.window }) else { fail("PREPARATION: keine Ablagezone im Baum") }
        check(u.drop(string: TrackDrag.prefix + t[1].key, at: u.center(prep)), "Drop auf PREPARATION nicht angenommen")
        u.spin(3) { store.preparation.contains(t[1].key) }
        check(store.preparation.contains(t[1].key), "PREPARATION nach dem Drop ohne den Track (\(store.preparation.count) Einträge)")
        log("drop auf preparation ok")
        // Tabelle: Zeile als Text ziehbar, Ablegen aus der eigenen Tabelle = Reihenfolge (zeigt die Playlist-Reihenfolge)
        store.editPlaylists("UI") { $0.addTracks(t.map(\.key), to: pl.id) }
        pane.sortOrder = [KeyPathComparator(\Track.title)]
        u.spin(3) { pane.shown.count == 3 }
        let shownKeys = pane.shown.map(\.key)
        let w = table.dataSource?.tableView?(table, pasteboardWriterForRow: 0) as? NSPasteboardItem
        check(w?.string(forType: .string) == TrackDrag.prefix + shownKeys[0], "Zeile ziehen: \(w?.string(forType: .string) ?? "nichts")")
        check((w?.string(forType: .fileURL) != nil) == (store.track(shownKeys[0])?.fileExists ?? false), "Zeile ziehen: Datei-Eintrag falsch")
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString(TrackDrag.prefix + t[2].key, forType: .string)
        let info = TableDragInfo(window: u.window, pasteboard: pb, source: table)
        let row = shownKeys.firstIndex(of: t[0].key) ?? 0
        check(table.dataSource?.tableView?(table, validateDrop: info, proposedRow: row, proposedDropOperation: .above) == .move, "Ablegen in der eigenen Tabelle: keine Verschiebung")
        check(table.dataSource?.tableView?(table, acceptDrop: info, row: row, dropOperation: .above) == true, "Ablegen in der Tabelle abgelehnt")
        let order = store.playlists.item(pl.id)?.tracks ?? []
        check(order == [t[2].key, t[0].key, t[1].key], "Reihenfolge nach dem Ziehen: \(order.map { k in t.firstIndex { $0.key == k } ?? -1 })")
        check(pane.sortOrder.isEmpty, "Liste zeigt nach dem Ziehen nicht die Playlist-Reihenfolge")
        u.spin(3) { pane.shown.map(\.key) == order }
        check(pane.shown.map(\.key) == order, "Liste in Playlist-Reihenfolge")
        // „Neue Playlist“ über das Menü: Umbenennen-Dialog, Name tippen, OK
        // Menü von PLAYLISTS (hat „Neue Smartlist …“, aber kein „Umbenennen …“ wie ein Ordner)
        guard let m2 = {
            for r in 0..<tree.numberOfRows {
                tree.scrollRowToVisible(r)
                let rect = tree.convert(tree.rect(ofRow: r), to: nil)
                if let m = u.rightClick(at: NSPoint(x: rect.minX + 60, y: rect.midY)), m.items.contains(where: { $0.title == String(localized: "Neue Playlist") }),
                   m.items.contains(where: { $0.title == String(localized: "Neue Smartlist …") }), !m.items.contains(where: { $0.title == String(localized: "Umbenennen …") }) { return m }
            }
            return nil
        }(), let ni = m2.items.firstIndex(where: { $0.title == String(localized: "Neue Playlist") }) else { fail("Menü „Neue Playlist“ fehlt") }
        let known = Set(store.playlists.all.map(\.id))
        m2.performActionForItem(at: ni)
        u.spin(5) { u.window.attachedSheet != nil }
        guard let alert = u.window.attachedSheet else { fail("Umbenennen-Dialog öffnet nicht") }
        func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
        let av = allViews(alert.contentView!)
        guard let nameField = av.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
              let ok = av.compactMap({ $0 as? NSButton }).first(where: { $0.title == String(localized: "OK") }) else { fail("Umbenennen-Dialog ohne Feld / OK") }
        alert.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
        nameField.currentEditor()?.insertText("UI Umbenannt")
        u.spin(0.2)
        ok.performClick(nil)
        u.spin(3) { u.window.attachedSheet == nil }
        let fresh = store.playlists.all.filter { !known.contains($0.id) }
        check(fresh.count == 1 && fresh[0].kind == .playlist && fresh[0].name == "UI Umbenannt", "Neue Playlist + Umbenennen: \(fresh.map(\.name))")
        log("tabelle: ziehen + reihenfolge ok · neue playlist über das menü + umbenennen ok")
        store.playlists = before
        PlaylistFile.flush()
        PlaylistFile.removeSelfTestDir()
    }
}

/// Ziehen-Information mit Quelle (Ablegen in derselben Tabelle = Reihenfolge)
final class TableDragInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    init(window: NSWindow, pasteboard: NSPasteboard, source: Any?) {
        draggingDestinationWindow = window
        draggingPasteboard = pasteboard
        draggingSource = source
    }
    var draggingLocation: NSPoint { .zero }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 2 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

extension UISelfTest {
    /// Mehrfach-Sortierung: Klick auf einen Spaltenkopf macht die Spalte zur ersten Sortierspalte, die bisherigen
    /// bleiben dahinter (Kommentar ▼, dann BPM: BPM ▲ · Kommentar ▼2); zweiter Klick dreht; Liste wirklich so sortiert
    /// Playlist der Collection im Baum als Ziel: Tracks ablegen geht in die Collection-Datei (nur die Kopie im Temp-Ordner
    /// des Fixtures), Smartlist zeigt den Hinweis, doppelt geht nicht, ohne Schreiben steht der Weg dorthin in der
    /// Statuszeile, ⌘Z schreibt die alte Reihenfolge zurück
    static func collectionDrop(_ u: UIDriver, _ t: [Track]) {
        let pane = u.browser.paneA, store = u.store
        let source = pane.source, showTree = pane.showTree, hide = u.mix.prefs.ui.hideTreeWithDecks, write = u.mix.prefs.ui.writeCollection
        pane.showTree = true
        u.mix.prefs.ui.hideTreeWithDecks = false
        u.mix.prefs.ui.writeCollection = true   // Schreiben an (nur die Kopie im Temp-Ordner wird geschrieben)
        defer {
            pane.source = source
            pane.showTree = showTree
            u.mix.prefs.ui.hideTreeWithDecks = hide
            u.mix.prefs.ui.writeCollection = write
        }
        u.spin(0.5)
        guard let url = store.sourceURL, url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            log("collection-drop: nur mit Fixture (Kopie im Temp-Ordner), übersprungen")
            return
        }
        guard let id = store.root.first(where: { $0.name == "UI Collection" })?.id else { fail("„UI Collection“ nicht im Baum") }
        guard let tree = u.views.compactMap({ $0 as? NSTableView }).filter({ !($0 is TrackNSTable) && $0.numberOfRows > 3 })
            .min(by: { u.frame($0).minX < u.frame($1).minX }) else { fail("Baum von Bereich A nicht gefunden") }
        func zone(_ name: String) -> NSView? {
            u.views.first { ($0 as? UITestNamed)?.name == name && $0.window === u.window }
        }
        // Zeilen aufscrollen, bis die Ablage der gesuchten Zeile da ist (SwiftUI legt Zeilen erst beim Sichtbarwerden an)
        func find(_ name: String) -> NSView? {
            for r in 0..<tree.numberOfRows {
                // Zeile nach oben scrollen: unten im Baum überdeckt das Fenster die Ablage (Trefferkette endet früher)
                tree.scroll(NSPoint(x: 0, y: tree.rect(ofRow: r).minY))
                u.spin(0.05)
                // nur oberhalb des unteren Randes: darunter trifft der Zug das Fenster nicht (Trefferkette endet früher)
                if let z = zone(name), u.frame(z).midY > 120 { return z }
            }
            return nil
        }
        let want = [t[0].key]
        // frische Ablage je Drop: das Scrollen nach einem Zug verschiebt die Zeilen
        func at(_ name: String) -> NSPoint { guard let z = find(name) else { fail("Ablage „\(name)“ im Baum fehlt") }; return u.center(z) }
        let file = { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        let fileAtStart = file()
        // Ablegen: Datei bekommt den Track, Sicherung liegt davor
        check(u.drop(string: TrackDrag.prefix + t[0].key, at: at("collection drop UI Collection")), "Drop auf „UI Collection“ nicht angenommen")
        u.spin(10) { store.collectionPlaylist(id)?.trackKeys == want }
        check(store.collectionPlaylist(id)?.trackKeys == want, "Nach dem Drop: \(store.collectionPlaylist(id)?.trackKeys ?? []) statt \(want) · Meldung \(store.status)")
        check((try? NMLParser.parse(url: url))?.root.first { $0.name == "UI Collection" }?.trackKeys == want, "Datei: Playlist ohne den Track")
        let backups = url.deletingLastPathComponent().appendingPathComponent("Backup MINOS-741")
        check((try? FileManager.default.contentsOfDirectory(atPath: backups.path))?.isEmpty == false, "keine Sicherung vor dem Schreiben")
        // doppelt: nichts ändert sich
        let once = file()
        check(u.drop(string: TrackDrag.prefix + t[0].key, at: at("collection drop UI Collection")), "Doppelter Drop nicht angenommen")
        u.spin(1)
        check(store.collectionPlaylist(id)?.trackKeys == want && file() == once, "Doppelter Track in der Playlist")
        // Smartlist: Hinweis, Datei bleibt
        check(u.drop(string: TrackDrag.prefix + t[1].key, at: at("collection drop UI Smart")), "Drop auf die Smartlist nicht angenommen")
        check(store.status == String(localized: "Smartlist – Tracks kommen über die Regel (Rechtsklick → Bearbeiten …)"), "Smartlist-Hinweis fehlt: \(store.status)")
        check(file() == once, "Smartlist-Drop hat die Datei geändert")
        // Schreiben aus: Hinweis mit dem Weg dorthin, Datei bleibt
        u.mix.prefs.ui.writeCollection = false
        let statusBefore = store.status
        check(u.drop(string: TrackDrag.prefix + t[1].key, at: at("collection drop UI Collection")), "Drop bei ausgeschaltetem Schreiben nicht angenommen")
        check(store.status.contains("UI Collection") && store.status != statusBefore, "Kein Hinweis bei ausgeschaltetem Schreiben: \(store.status)")
        check(file() == once, "bei ausgeschaltetem Schreiben hat sich die Datei geändert")
        u.mix.prefs.ui.writeCollection = true
        // ⌘Z: alte Reihenfolge (leer) zurück in die Datei
        let label = UndoStack.shared.undo()
        check(label == String(localized: "Zur Playlist hinzufügen"), "Rückgängig: „\(label ?? "-")“")
        u.spin(10) { store.collectionPlaylist(id)?.trackKeys == [] }
        check(store.collectionPlaylist(id)?.trackKeys == [], "⌘Z holt die alte Reihenfolge nicht zurück")
        check((try? NMLParser.parse(url: url))?.root.first { $0.name == "UI Collection" }?.trackKeys == [], "Datei nach ⌘Z nicht leer")
        check(fileAtStart.contains("UI Collection"), "Fixture ohne UI Collection")
        log("collection-drop: ablegen, Sicherung, doppelt, smartlist, schreiben aus, ⌘Z ok")
    }

    static func multiSort(_ u: UIDriver, _ t: [Track]) {
        let pane = u.browser.paneA
        let order0 = pane.sortOrder, source0 = pane.source
        defer { pane.sortOrder = order0; pane.source = source0; u.spin(0.3) }
        pane.source = .collection
        pane.sortOrder = [KeyPathComparator(\Track.artist)]
        u.spin(3) { !pane.listPending && !pane.shown.isEmpty }
        func findHead() -> TrackHeaderView? {
            u.views.compactMap({ $0 as? TrackHeaderView }).first(where: { h in
                guard let tv = h.tableView else { return false }
                return tv.numberOfRows == pane.shown.count && u.frame(h).minX < u.window.frame.width / 2
            })
        }
        u.spin(5) { findHead() != nil }   // Tabelle lädt die Collection nach dem Quellwechsel
        guard let head = findHead(), let tv = head.tableView else { fail("Tabellenkopf von Bereich A nicht gefunden") }
        // die Tabelle muss die Sortierung des Bereichs übernommen haben, sonst stapelt AppKit nichts dahinter
        u.spin(2) { tv.sortDescriptors.map(\.key) == ["artist"] }
        check(tv.sortDescriptors.map(\.key) == ["artist"], "Tabelle zeigt nicht die Artist-Sortierung: \(tv.sortDescriptors.map { $0.key ?? "?" })")
        func header(_ id: String) -> NSPoint {
            guard let i = tv.tableColumns.firstIndex(where: { $0.identifier.rawValue == id && !$0.isHidden }) else { fail("Spalte \(id) fehlt") }
            // Spalte sichtbar machen (breite Tabellen: sonst klickt der Test neben das Fenster)
            tv.scrollColumnToVisible(i)
            u.spin(0.2)
            let r = head.headerRect(ofColumn: i)
            return head.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
        }
        func mark(_ id: String) -> String {
            tv.tableColumns.first { $0.identifier.rawValue == id }.flatMap { ($0.headerCell as? TrackHeaderCell)?.sortMark } ?? "?"
        }
        u.click(at: header("comment"))   // Kommentar ▲
        u.spin(1) { pane.sortOrder.first?.keyPath == \Track.comment }
        u.click(at: header("comment"))   // Kommentar ▼
        u.spin(1) { pane.sortOrder.first?.order == .reverse }
        check(pane.sortOrder.map(\.keyPath) == [\Track.comment, \Track.artist] && pane.sortOrder.first?.order == .reverse,
              "Kommentar ▼ (Artist dahinter) nach zwei Klicks: \(pane.sortOrder.map { "\($0.keyPath) \($0.order)" })")
        u.click(at: header("bpm"))       // BPM ▲ davor, Kommentar ▼ dahinter
        u.spin(2) { pane.sortOrder.count == 3 && !pane.listPending }
        u.spin(0.3)
        check(pane.sortOrder.map(\.keyPath) == [\Track.bpm, \Track.comment, \Track.artist], "BPM, Kommentar, Artist: \(pane.sortOrder.map { "\($0.keyPath)" })")
        check(mark("bpm") == "▲" && mark("comment") == "▼2" && mark("artist") == "▲3", "Marken: bpm „\(mark("bpm"))“ kommentar „\(mark("comment"))“ artist „\(mark("artist"))“")
        // Liste: BPM aufsteigend, bei gleichem BPM Kommentar absteigend
        let rows = pane.shown
        var ok = true, pairs = 0
        for (a, b) in zip(rows, rows.dropFirst()) {
            if a.bpm > b.bpm { ok = false; break }
            if a.bpm == b.bpm { pairs += 1; if a.comment.localizedCaseInsensitiveCompare(b.comment) == .orderedAscending { ok = false; break } }
        }
        check(ok, "Liste nicht nach BPM ▲ / Kommentar ▼ sortiert")
        u.click(at: header("bpm"))       // BPM ▼, Kommentar bleibt
        u.spin(1) { pane.sortOrder.first?.order == .reverse }
        check(pane.sortOrder.map(\.keyPath) == [\Track.bpm, \Track.comment, \Track.artist] && pane.sortOrder.first?.order == .reverse,
              "BPM ▼ dreht nur die erste: \(pane.sortOrder.map { "\($0.keyPath) \($0.order)" })")
        // vierte Spalte: höchstens drei bleiben
        u.click(at: header("title"))
        u.spin(1) { pane.sortOrder.first?.keyPath == \Track.title }
        check(pane.sortOrder.map(\.keyPath) == [\Track.title, \Track.bpm, \Track.comment], "höchstens drei Spalten: \(pane.sortOrder.map { "\($0.keyPath)" })")
        pane.sortOrder = [KeyPathComparator(\Track.bpm, order: .reverse), KeyPathComparator(\Track.comment, order: .reverse)]
        u.spin(0.3)
        // Sitzung: alle Spalten
        let session = Session(mix: u.mix, browser: u.browser)
        check(session.panes?.first?.sorts == ["bpm:desc", "comment:desc"], "Sitzung: \(session.panes?.first?.sorts ?? [])")
        log("mehrfach-sortierung: \(pane.sortOrder.count) spalten, \(pairs) gleiche bpm-paare geprüft, marken \(mark("bpm")) \(mark("comment"))")
    }
}

extension UISelfTest {
    /// ⌘, -> ANZEIGE -> Wellenform (eigenes Fenster, offscreen): KOPIEREN legt eine eigene Kopie des eingebauten Presets
    /// an und wählt sie, der Regler Trennfrequenz Tief ändert sie (Deck A rechnet nach), die Kopie steht im Preset-Menü.
    /// Danach gelöscht, Auswahl wie vorher
    /// Beatgrid-Linien fein / kräftig: Auswahl in ⌘, -> ANZEIGE vorhanden; umschalten ändert die Linienbreiten der
    /// Grid-Ebene im Deck (Gerätepixel aus der Ebene, kein Bildvergleich)
    /// ⌘, DECKS: Cover-Breite und Übersicht-Höhe (Werte direkt gesetzt). Cover 120 pt: eigene Spalte links, quadratisch,
    /// Kopf rechts daneben und nicht höher; Übersicht 90 pt hoch, Bild in passender Auflösung. 4 Decks, Cover 200 pt:
    /// begrenzt, rechts bleiben `DeckCoverFit.minRest` pt
    static func deckSizes(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        let ui0 = mix.prefs.ui
        defer { mix.prefs.ui = ui0; u.spin(0.5) }
        let root = SettingsView(selection: "DECKS").environment(mix).environment(u.browser).environment(u.store)
        let host = NSHostingView(rootView: root)
        let w = UITestWindow(contentRect: NSRect(origin: UITestWindow.origin, size: NSSize(width: 900, height: 4000)), styleMask: [.titled],
                             backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.contentView = host
        w.orderFrontRegardless()
        func marks() -> [String] {
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            return all(w.contentView?.superview ?? host).compactMap { ($0 as? UITestMark.V)?.name }
        }
        u.spin(5) { Set(marks()).isSuperset(of: ["cover size", "overview height"]) }
        let found = Set(marks()).isSuperset(of: ["cover size", "overview height"])
        w.orderOut(nil)
        check(found, "⌘, DECKS: Regler Cover-Breite / Übersicht Höhe fehlen")

        // Übersicht: LiveCanvas in Deck A, breit, unter der Wellenform (Phasenbalken 8 pt, Übersicht ab 12 pt)
        func overview() -> NSRect? {
            guard let deck = u.named("deck A") else { return nil }
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            let dw = u.frame(deck).width
            return all(deck).compactMap { $0 as? LiveCanvasView }.map { u.frame($0) }
                .filter { $0.width > dw / 2 && $0.height >= 11 }.max { $0.height < $1.height }
        }
        func header() -> NSRect? { u.named("A header").map { u.frame($0) } }
        mix.prefs.ui.deckCoverSize = UIPrefs().deckCoverSize
        mix.prefs.ui.overviewHeight = UIPrefs().overviewHeight
        u.spin(2) { overview().map { abs($0.height - 18) < 1 } ?? false }
        guard let ov0 = overview(), header() != nil else { fail("Deck A: Übersicht oder Kopf nicht gefunden") }
        check(abs(ov0.height - 18) < 1, "Übersicht Standard \(ov0.height) pt statt 18")
        check(u.named("A cover") == nil, "Cover-Spalte schon bei 32 pt")
        // Bezug: kleinste Spalte (Kopf ohne Cover, neu gemessen; frühere Fälle können die alte Messung hinterlassen)
        mix.prefs.ui.deckCoverSize = 44
        u.spin(2) { u.named("A cover") != nil }
        guard let h0 = header() else { fail("Deck A: Kopf fehlt") }

        mix.prefs.ui.deckCoverSize = 120
        mix.prefs.ui.overviewHeight = 90
        u.spin(3) { u.named("A cover") != nil && (overview().map { abs($0.height - 90) < 1 } ?? false) }
        guard let cv = u.named("A cover").map({ u.frame($0) }), let ov = overview(), let h1 = header() else { fail("Cover-Spalte oder Übersicht fehlt nach dem Setzen") }
        check(abs(cv.width - cv.height) < 1, "Cover nicht quadratisch: \(cv.size)")
        check(abs(cv.width - 120) < 1, "Cover \(cv.width) pt statt 120 (Deck \(u.frame(u.named("deck A")!).width) pt)")
        check(abs(ov.height - 90) < 1, "Übersicht \(ov.height) pt statt 90")
        check(abs(h1.height - h0.height) < 1 && h1.height < cv.height, "Kopf wächst mit dem Cover: \(h0.height) → \(h1.height) pt")
        check(h1.minX >= cv.maxX, "Kopf nicht rechts vom Cover: Kopf ab \(h1.minX), Cover bis \(cv.maxX)")
        check(ov.minX >= cv.maxX, "Übersicht nicht rechts vom Cover")
        let want = RenderedWaveform.overviewPixels(points: 90, zoom: mix.prefs.ui.zoom)
        let cache = WaveformCache()
        u.spin(30) { cache.waveform(for: mix.core.trackAudio(0), ui: mix.prefs.ui, preset: mix.wavePreset)?.overview?.height == want }
        let px = cache.waveform(for: mix.core.trackAudio(0), ui: mix.prefs.ui, preset: mix.wavePreset)?.overview?.height ?? 0
        check(px == want, "Übersichtsbild \(px) px hoch statt \(want)")

        // 4 Decks, Cover 200: Breite begrenzt, Titel und Anzeigen behalten ihren Platz
        mix.prefs.ui.deckCount = 4
        mix.prefs.ui.deckCoverSize = 200
        u.spin(2)
        u.spin(3) { u.named("A cover") != nil }
        guard let deck4 = u.named("deck A").map({ u.frame($0) }), let h4 = header() else { fail("4 Decks: Deck A fehlt") }
        let cv4 = u.named("A cover").map { u.frame($0) }
        let side4 = cv4?.width ?? 0
        check(side4 <= 200 + 0.5, "Cover \(side4) pt über 200")
        check(h4.width >= DeckCoverFit.minRest - 8 || side4 == 0, "Kopf neben dem Cover nur \(h4.width) pt (Deck \(deck4.width) pt, Cover \(side4) pt)")
        check(abs(h4.height - h0.height) < 1, "Kopf bei 4 Decks \(h4.height) statt \(h0.height) pt")
        log(String(format: "deck-groessen: 2 decks cover %.0f pt, kopf %.0f pt hoch (vorher %.0f), übersicht %.0f pt / %d px · 4 decks deck %.0f pt, cover %.0f pt, kopf %.0f pt breit",
                   cv.width, h1.height, h0.height, ov.height, px, deck4.width, side4, h4.width))
        if let out = ProcessInfo.processInfo.environment["MIX741_UITEST_SIZESHOT"] { shot(u, out, "deck-groessen") }
    }

    static func gridLines(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        let weight0 = mix.prefs.ui.gridLineWeight, grid0 = mix.prefs.ui.showBeatgrid
        defer { mix.prefs.ui.gridLineWeight = weight0; mix.prefs.ui.showBeatgrid = grid0; u.spin(0.3) }
        let root = SettingsView(selection: "ANZEIGE").environment(mix).environment(u.browser).environment(u.store)
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: 900, height: 4000)
        let w = UITestWindow(contentRect: NSRect(origin: UITestWindow.origin, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.contentView = host
        w.orderFrontRegardless()
        func settingsViews() -> [NSView] {
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            return all(w.contentView?.superview ?? host)
        }
        u.spin(5) { settingsViews().contains { ($0 as? UITestMark.V)?.name == "grid lines" } }
        let found = settingsViews().contains { ($0 as? UITestMark.V)?.name == "grid lines" }
        w.orderOut(nil)
        check(found, "⌘, ANZEIGE: Auswahl Linien fehlt")
        func layer() -> WaveLayerNSView? { u.views.compactMap { $0 as? WaveLayerNSView }.first { $0.gridPixels.bar > 0 } }
        mix.prefs.ui.showBeatgrid = true
        mix.prefs.ui.gridLineWeight = .fine
        u.spin(2) { layer() != nil }
        guard let v = layer() else { fail("Deck: keine Grid-Ebene") }
        let fine = v.gridPixels
        mix.prefs.ui.gridLineWeight = .bold
        u.spin(2) { v.gridPixels != fine }
        let bold = v.gridPixels
        check(bold.bar > fine.bar && bold.beat >= fine.beat, "Linien kräftig: Takt \(bold.bar) px / Beat \(bold.beat) px statt breiter als fein (\(fine.bar) / \(fine.beat))")
        mix.prefs.ui.gridLineWeight = .fine
        u.spin(2) { v.gridPixels == fine }
        check(v.gridPixels == fine, "zurück auf fein: \(v.gridPixels) statt \(fine)")
        log("linien: fein Beat \(fine.beat) px · Takt \(fine.bar) px, kräftig Beat \(bold.beat) px · Takt \(bold.bar) px")
    }

    static func wavePreset(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, store = mix.wavePresets
        let style0 = mix.prefs.ui.waveformStyle, preset0 = mix.prefs.ui.wavePreset, n0 = store.list.custom.count
        mix.prefs.ui.waveformStyle = .blend
        mix.selectWavePreset("blend.a")
        let root = SettingsView(selection: "ANZEIGE").environment(mix).environment(u.browser).environment(u.store)
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: 900, height: 4000)
        let w = UITestWindow(contentRect: NSRect(origin: UITestWindow.origin, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.setContentSize(size)
        w.orderFrontRegardless()
        defer {
            if mix.wavePreset.builtIn == false { mix.deleteWavePreset() }
            mix.prefs.ui.wavePreset = preset0
            mix.prefs.ui.waveformStyle = style0
            w.orderOut(nil)
            u.spin(0.3)
        }
        func views() -> [NSView] {
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            return all(w.contentView?.superview ?? host)
        }
        func mark(_ name: String) -> NSView? { views().first { ($0 as? UITestMark.V)?.name == name } }
        func frame(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }
        u.spin(5) { mark("wave copy") != nil && mark("wave low") != nil }
        guard let copyMark = mark("wave copy") else { fail("Wellenform: Taste KOPIEREN nicht gefunden") }
        // Klick direkt an die getroffene Ansicht; kommt er nicht an (CI-Runner), die Aktion direkt (steht im Log)
        let r = frame(copyMark), p = NSPoint(x: r.midX, y: r.midY)
        let top = w.contentView?.superview ?? host
        if let hit = top.hitTest(top.convert(p, from: nil)) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { fail("kein Mausereignis") }
                if type == .leftMouseDown { hit.mouseDown(with: e) } else { hit.mouseUp(with: e) }
            }
        }
        u.spin(1) { store.list.custom.count == n0 + 1 }
        if store.list.custom.count == n0 {
            log("wellenform-preset: klick auf KOPIEREN kommt nicht an – kopiere direkt")
            mix.copyWavePreset()
        }
        let copy = mix.wavePreset
        check(store.list.custom.count == n0 + 1 && !copy.builtIn && copy.base == "blend.a", "KOPIEREN legt keine eigene Kopie an")
        check(copy.look == WavePresets.builtIn[0].look && copy.analysis == .standard, "Kopie hat andere Werte als A")
        // Regler Trennfrequenz Tief: NSSlider in der Zeile auf 3/4 (log 40…400 Hz -> 225 Hz)
        u.spin(1)
        let row = mark("wave low").map(frame)
        let slider = row.flatMap { rr in views().compactMap { $0 as? NSSlider }.first { frame($0).intersects(rr) } }
        if let slider {
            slider.doubleValue = slider.minValue + (slider.maxValue - slider.minValue) * 0.75
            _ = slider.sendAction(slider.action, to: slider.target)
            u.spin(0.5) { mix.wavePreset.analysis.low != 150 }
        }
        if mix.wavePreset.analysis.low == 150 {
            log("wellenform-preset: regler \(slider == nil ? "nicht gefunden" : "reagiert nicht") – setze direkt")
            mix.editWavePreset { $0.analysis.low = 225 }
        }
        let low = mix.wavePreset.analysis.low
        check(mix.wavePreset.id == copy.id && abs(low - 225) < 15, "Regler Tief: \(low) Hz, soll ≈ 225 (Preset \(mix.wavePreset.name))")
        check(store.list.preset(copy.id)?.analysis.low == low && store.list.builtIn[0].analysis.low == 150, "Änderung nicht in der Kopie")
        // Kopie steht im Preset-Menü
        u.spin(0.5)
        let popup = mark("wave picker").map(frame).flatMap { pr in views().compactMap { $0 as? NSPopUpButton }.first { frame($0).intersects(pr) } }
        if let popup {
            check(popup.itemTitles.contains(copy.name), "Preset-Menü ohne „\(copy.name)“: \(popup.itemTitles)")
        } else {
            check(store.all.contains { $0.id == copy.id }, "Kopie nicht in der Liste")
            log("wellenform-preset: preset-menü nicht als NSPopUpButton gefunden – liste geprüft")
        }
        // Deck A rechnet mit der neuen Trennfrequenz nach
        let cache = WaveformCache()
        if let a = mix.core.trackAudio(0) {
            u.spin(30) { cache.waveform(for: a, ui: mix.prefs.ui, preset: mix.wavePreset) != nil }
            check(cache.waveform(for: a, ui: mix.prefs.ui, preset: mix.wavePreset) != nil && cache.reanalyzed == 1, "keine Nachanalyse für Deck A")
        }
        log(String(format: "wellenform-preset: „%@“ · tief %.0f Hz · nachanalyse %.2f s", copy.name, low, cache.lastReanalysis))
    }
}

extension UISelfTest {
    /// Aufnahme: Klick auf ● REC in der oberen Leiste startet (interner Master, Temp-Ordner), die Laufzeit läuft, zweiter
    /// Klick stoppt, Statuszeile meldet die Datei. Kommt der synthetische Klick nicht an: Direktaktion (steht im Log)
    static func recording(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, rec = mix.recorder
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-uitest-rec-\(getpid())", isDirectory: true)
        let saved = mix.prefs.record
        rec.folderOverride = dir
        rec.history = u.browser.history
        mix.prefs.record.source = .master
        defer { rec.folderOverride = nil; mix.prefs.record = saved; try? FileManager.default.removeItem(at: dir) }
        if !mix.deck(0).playing { mix.togglePlay(0) }
        u.spin(0.3)
        guard let mark = u.views.compactMap({ $0 as? UITestMark.V }).first(where: { $0.name == "rec" }) else { fail("● REC nicht gefunden") }
        let r = u.frame(mark), p = NSPoint(x: r.midX, y: r.midY)
        check(r.width > 10 && u.window.contentView?.bounds.contains(p) == true, "● REC liegt außerhalb: \(r)")
        let root = u.window.contentView?.superview ?? u.host
        func press(_ want: Bool) {
            if let hit = root.hitTest(root.convert(p, from: nil)) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: u.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { fail("kein Mausereignis") }
                    if type == .leftMouseDown { hit.mouseDown(with: e) } else { hit.mouseUp(with: e) }
                }
            }
            u.spin(1) { rec.recording == want }
            if rec.recording != want {
                log("aufnahme: klick auf ● REC kommt nicht an – schalte direkt")
                rec.toggle()
            }
        }
        press(true)
        check(rec.recording, "Aufnahme startet nicht: \(StatusCenter.shared.current?.text ?? "-")")
        u.spin(1.6)
        let ran = rec.elapsed()
        check(ran >= 1.4, "Laufzeit steht: \(ran) s")
        let url = rec.url
        press(false)
        u.spin(3) { !rec.recording && rec.lastStats != nil }
        check(!rec.recording, "Aufnahme stoppt nicht")
        let want = String(localized: "Aufnahme gespeichert: \(url?.lastPathComponent ?? "?") · \(SetRecorder.clock(ran))")
        let text = StatusCenter.shared.history.first { $0.text.hasPrefix(String(want.prefix(22))) }?.text ?? ""
        check(text.contains(url?.lastPathComponent ?? "?"), "Statuszeile ohne „\(want)“: \(StatusCenter.shared.history.prefix(3).map(\.text))")
        check(url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "Datei fehlt")
        log(String(format: "aufnahme: %@ · %.1f s · %@", url?.lastPathComponent ?? "?", ran, text))
    }
    /// Rip-Prüfung: Befund (fremder Anfang 4 s) für Track C im Speicher -> Spalte „▸ 4,0 s“, Klick auf ◆ RIP filtert
    /// Bereich A auf genau diesen Track, Quelle ZU BEARBEITEN enthält ihn; Rechtsklick-Eintrag „Schnitt IN auf 4,0 s
    /// setzen“ -> trimStart 4 s in edits (nur Speicher), Befund erledigt, Liste leer. Danach alles zurück
    /// ⌘, DECKS: Auswahl Auto-Loop; 8 Takte, Track ohne Loop in Deck B: inaktiver Loop über 8 Takte, Rahmen mit AUTO
    static func autoLoop(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, d = 1, bars0 = mix.prefs.engine.autoLoopBars
        func loaded(_ key: String) -> Bool { let s = mix.core.snapshot().decks[d]; return !s.loading && s.track?.key == key && mix.core.trackAudio(d) != nil }
        defer {
            mix.prefs.engine.autoLoopBars = bars0
            _ = mix.load(t[1], deck: d, force: true)
            u.spin(30) { loaded(t[1].key) }
            mix.pull()
        }
        let root = SettingsView(selection: "DECKS").environment(mix).environment(u.browser).environment(u.store)
        let host = NSHostingView(rootView: root)
        let w = UITestWindow(contentRect: NSRect(origin: UITestWindow.origin, size: NSSize(width: 900, height: 4000)), styleMask: [.titled],
                             backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.contentView = host
        w.orderFrontRegardless()
        func settingsViews() -> [NSView] {
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            return all(w.contentView?.superview ?? host)
        }
        u.spin(5) { settingsViews().contains { ($0 as? UITestMark.V)?.name == "auto loop" } }
        let found = settingsViews().contains { ($0 as? UITestMark.V)?.name == "auto loop" }
        w.orderOut(nil)
        check(found, "⌘, DECKS: Auswahl Auto-Loop fehlt")
        mix.prefs.engine.autoLoopBars = 8
        if mix.deck(d).playing { mix.togglePlay(d) }
        var track = t[1]
        track.cues.removeAll { $0.kind == .loop }
        mix.core.load(track, deck: d)
        u.spin(30) { loaded(track.key) }
        mix.pull()
        let s = mix.deck(d), l = mix.engine.loop(d)
        guard let g = s.grid else { fail("AUTO-LOOP: Deck B ohne Grid") }
        check(s.autoLoop && !l.active && abs(l.end - l.start - 32 * g.beat) < 1e-6,
              String(format: "AUTO-LOOP: auto %@ aktiv %@ · %.3f–%.3f s statt 8 Takte (%.3f s)", "\(s.autoLoop)", "\(l.active)", l.start, l.end, 32 * g.beat))
        func shown() -> Bool {
            u.views.compactMap { $0 as? WaveLayerNSView }.contains { v in v.autoLoopShown.map { abs($0.start - l.start) < 1e-9 && abs($0.end - l.end) < 1e-9 } ?? false }
        }
        u.spin(3) { shown() }
        check(shown(), "AUTO-LOOP: Rahmen mit AUTO in der Wellenform fehlt")
        log(String(format: "auto-loop: %.3f–%.3f s (8 takte), nicht aktiv, rahmen mit AUTO", l.start, l.end))
    }

    static func ripCheck(_ u: UIDriver, _ t: [Track]) {
        let pane = u.browser.paneA, rips = RipChecks.shared, track = t[2]
        let mix0 = rips.mix, lib0 = rips.library, source0 = pane.source, edit0 = u.mix.edits.edit(for: track.key)
        rips.mix = u.mix
        rips.library = u.store
        defer {
            rips.store.remove([track.key]); u.mix.edits.set(edit0, for: track.key)
            rips.mix = mix0; rips.library = lib0; pane.ripOnly = false; pane.source = source0; u.spin(0.5)
        }
        u.mix.edits.set(nil, for: track.key)
        let f = RipCheck.Finding(kind: .foreign, edge: .start, time: 4, confidence: 0.8, cues: [.key])
        rips.store.put(RipCheck.Result(findings: [f], duration: track.duration), for: track.key)
        u.spin(2) { rips.openKeys.contains(track.key) }
        check(rips.openKeys == [track.key], "RIP: offene Befunde \(rips.openKeys)")
        check(rips.columnText(track.key) == "▸ 4,0 s", "RIP: Spalte „\(rips.columnText(track.key))“")
        check(u.store.tracks(for: .ripTodo).map(\.key) == [track.key], "RIP: ZU BEARBEITEN \(u.store.tracks(for: .ripTodo).map(\.title))")
        pane.source = .collection
        u.spin(5) { !pane.listPending && !pane.shown.isEmpty }
        guard let marker = u.views.compactMap({ $0 as? UITestMark.V }).filter({ $0.name == "rip chip" })
            .min(by: { u.frame($0).minX < u.frame($1).minX }) else { fail("Knopf ◆ RIP nicht gefunden") }
        let r = u.frame(marker), p = NSPoint(x: r.midX, y: r.midY)
        check(r.width > 10 && u.window.contentView?.bounds.contains(p) == true, "◆ RIP liegt außerhalb: \(r)")
        let root = u.window.contentView?.superview ?? u.host
        if let hit = root.hitTest(root.convert(p, from: nil)) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: u.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { fail("kein Mausereignis") }
                if type == .leftMouseDown { hit.mouseDown(with: e) } else { hit.mouseUp(with: e) }
            }
        }
        u.spin(1) { pane.ripOnly }
        if !pane.ripOnly { log("rip: klick auf den knopf kommt nicht an – schalte direkt"); pane.ripOnly = true }
        u.spin(5) { !pane.listPending && pane.shown.map(\.key) == [track.key] }
        check(pane.shown.map(\.key) == [track.key], "◆ RIP: \(pane.shown.count) Zeilen, soll nur \(track.title)")
        // Rechtsklick-Menü des Tracks: Eintrag ausführen
        let menu = NSMenu()
        rips.addMenuItems(menu, tracks: { [track] }, single: track)
        guard let i = menu.items.firstIndex(where: { $0.title == String(localized: "Schnitt IN auf \(RipCheck.shortTime(4)) setzen") }) else {
            fail("RIP: Menü ohne Schnitt IN: \(menu.items.map(\.title))")
        }
        menu.performActionForItem(at: i)
        u.spin(2) { !rips.openKeys.contains(track.key) }
        check(u.mix.edits.edit(for: track.key)?.trimStart == 4, "RIP: Schnitt IN \(String(describing: u.mix.edits.edit(for: track.key)?.trimStart))")
        check(rips.open(track.key).isEmpty && !rips.openKeys.contains(track.key), "RIP: Befund nach Schnitt IN noch offen")
        u.spin(5) { !pane.listPending && pane.shown.isEmpty }
        check(pane.shown.isEmpty, "◆ RIP nach Schnitt IN: \(pane.shown.count) Zeilen")
        log("rip: spalte ▸ 4,0 s · ◆ RIP 1 zeile · schnitt IN gesetzt · erledigt")
    }

    /// Befund am geladenen Track von Deck A (ohne EDIT): RIP markiert 0 … 4 s mit „RIP · …“, Rechtsklick in den Bereich ->
    /// „Markierten Bereich entfernen“ (EDIT an, Schnittliste) -> Befund erledigt, Bereich weg. Kommt der Rechtsklick nicht
    /// an, die Aktion direkt (Weg im Log). Danach Rückgängig, EDIT wie vorher
    static func ripRange(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, d = 0, rips = RipChecks.shared
        guard let track = mix.deck(d).track else { fail("RIP-Bereich: Deck A leer") }
        if mix.deck(d).playing { mix.togglePlay(d) }
        let mix0 = rips.mix, edit0 = mix.edits.edit(for: track.key), wasEditing = mix.editing(d), undo0 = UndoStack.shared.done.count
        rips.mix = mix
        defer {
            while UndoStack.shared.done.count > undo0 { UndoStack.shared.undo() }
            u.spin(5) { mix.editSession(d)?.rendering != true }
            mix.setRange(d, nil)
            mix.setEditing(d, wasEditing)
            rips.store.remove([track.key]); mix.edits.set(edit0, for: track.key); rips.mix = mix0
            u.spin(0.5)
        }
        mix.edits.set(nil, for: track.key)
        mix.setEditing(d, false)
        mix.setRange(d, nil)
        let f = RipCheck.Finding(kind: .foreign, edge: .start, time: 4, confidence: 0.8, cues: [.key])
        rips.store.put(RipCheck.Result(findings: [f], duration: mix.deck(d).duration), for: track.key)
        u.spin(2) { rips.openKeys.contains(track.key) }
        check(mix.markNextRip(d), "RIP-Bereich: RIP markiert nichts (\(rips.open(track.key).map(\.id)))")
        guard let range = mix.range(d), let label = mix.rangeMarked(d, grid: mix.deck(d).grid)?.label else { fail("RIP-Bereich: kein Bereich") }
        check(range == TrackRange(0, 4) && label.hasPrefix("RIP · "), "RIP-Bereich: \(range) „\(label)“")
        check(rips.openKeys.contains(track.key), "RIP-Bereich: Markieren erledigt den Befund schon")
        guard let w = u.views.compactMap({ $0 as? WaveMouseView }).first(where: { $0.d == d }) else { fail("Wellenform A nicht gefunden") }
        mix.core.seek(d, seconds: 2)   // Mitte der Wellenform im Bereich
        mix.pull()
        u.spin(0.3)
        let dur0 = mix.deck(d).duration, r = u.frame(w)
        let item = String(localized: "Markierten Bereich entfernen")
        var via = "rechtsklick"
        if let menu = u.rightClick(at: NSPoint(x: r.midX, y: r.midY)), let i = menu.items.firstIndex(where: { $0.title == item }) {
            check(i <= 5, "RIP-Bereich: „\(item)“ nicht oben: \(menu.items.map(\.title))")   // unter „Track ▸“
            check(menu.items.contains { $0.title == String(localized: "Markierten Bereich entfernen (neue Datei)") }, "RIP-Bereich: ohne „… (neue Datei)“")
            menu.performActionForItem(at: i)
        } else {
            via = "direkt (rechtsklick nicht zugestellt)"
            mix.removeMarkedRange(d)
        }
        u.spin(10) { mix.editSession(d)?.preview != nil && mix.editSession(d)?.rendering == false }
        let dur1 = mix.deck(d).duration
        check(mix.editing(d), "RIP-Bereich: EDIT nicht an")
        check(abs(dur1 - (dur0 - 4)) < 0.01, "RIP-Bereich: Dauer \(dur0) -> \(dur1), soll 4 s weniger")
        check(mix.range(d) == nil && mix.ripMark(d) == nil, "RIP-Bereich: Bereich nach dem Entfernen noch da")
        u.spin(2) { !rips.openKeys.contains(track.key) }
        check(rips.open(track.key).isEmpty && rips.store.entry(for: track.key)?.done == [f.id], "RIP-Bereich: Befund nicht erledigt")
        log("rip-bereich: „\(label)“ · \(via) -> entfernt \(String(format: "%.1f", dur0 - dur1)) s · erledigt")
    }
}

extension UISelfTest {
    /// Einstellungen in eigenem Offscreen-Fenster (900 × 600, scrollt): „puffer“ ins Suchfeld, erster Treffer per Klick
    /// -> Bereich AUDIO, Zeile Puffer lila und sichtbar; „parallel“ + Enter -> Zeile ganz unten in AUDIO sichtbar
    /// (Sprung scrollt); esc leert; `settingsRequest` öffnet PLUGINS. Kommt ein synthetisches Ereignis nicht an: Direktaktion (steht im Log)
    static func settingsSearch(_ u: UIDriver, _ t: [Track]) {
        let nav = SettingsNav(tab: "DECKS")
        let root = SettingsView(selection: "DECKS", nav: nav).environment(u.mix).environment(u.browser).environment(u.store)
            .environment(ControllerStatus())
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: 900, height: 600)
        let w = UITestWindow(contentRect: NSRect(origin: UITestWindow.origin, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.setContentSize(size)
        w.orderFrontRegardless()
        defer {
            w.orderOut(nil)
            u.spin(0.3)
        }
        func views() -> [NSView] {
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            return all(w.contentView?.superview ?? host)
        }
        func mark(_ name: String) -> NSView? { views().first { ($0 as? UITestMark.V)?.name == name } }
        func frame(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }
        u.spin(5) { mark("settings search") != nil }
        guard let fieldMark = mark("settings search") else { fail("Einstellungen: Suchfeld nicht gefunden") }
        let field = views().compactMap { $0 as? NSTextField }.first { $0.isEditable && frame($0).intersects(frame(fieldMark)) }
        func type(_ text: String) {
            if let field, w.makeFirstResponder(field), let ed = field.currentEditor() as? NSTextView {
                ed.selectAll(nil)
                ed.insertText(text, replacementRange: ed.selectedRange())
            }
            u.spin(1) { nav.query == text && nav.showResults }
            if nav.query != text {
                log("einstellungen-suche: tippen ins suchfeld kommt nicht an – setze direkt")
                nav.query = text
                u.spin(0.5)
            }
        }
        /// Zeile mit lila Rahmen: sichtbar im Fenster?
        func flashed(_ anchor: String) -> NSRect? {
            u.spin(2) { nav.flash == anchor && mark("settings flash") != nil }
            guard nav.flash == anchor, let m = mark("settings flash") else { return nil }
            return frame(m)
        }
        let content = NSRect(origin: .zero, size: size)

        // „puffer“ -> Trefferliste, Klick auf den ersten Treffer
        type("puffer")
        let hits = SettingsSearch.shared.search("puffer")
        check(hits.first?.entry.anchor == "audio.buffer", "erster Treffer für „puffer“: \(hits.first?.entry.anchor ?? "-")")
        u.spin(2) { mark("settings hit") != nil }
        guard let hitMark = mark("settings hit") else { fail("Trefferliste ohne Treffer") }
        let r = frame(hitMark), p = NSPoint(x: r.midX, y: r.midY)
        let top = w.contentView?.superview ?? host
        if let hit = top.hitTest(top.convert(p, from: nil)) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { fail("kein Mausereignis") }
                if type == .leftMouseDown { hit.mouseDown(with: e) } else { hit.mouseUp(with: e) }
            }
        }
        u.spin(1) { nav.tab == "AUDIO" && !nav.showResults }
        if nav.showResults {
            log("einstellungen-suche: klick auf den treffer kommt nicht an – springe direkt")
            nav.open(hits[0].entry)
        }
        check(nav.tab == "AUDIO" && !nav.showResults, "Sprung: Bereich \(nav.tab), Trefferliste \(nav.showResults)")
        check(nav.query == "puffer", "Suche nach dem Sprung geleert")
        guard let buf = flashed("audio.buffer") else { fail("Zeile Puffer nicht hervorgehoben (flash \(nav.flash ?? "-"))") }
        check(content.contains(NSPoint(x: buf.midX, y: buf.midY)), "Zeile Puffer nicht sichtbar: \(buf)")

        // „parallel“ + Enter: letzte Zeile von AUDIO, muss gescrollt werden
        type("decks parallel")
        check(nav.showResults, "Trefferliste kommt nach neuer Eingabe nicht zurück")
        if let ed = field?.currentEditor() as? NSTextView { ed.insertNewline(nil) }
        u.spin(1) { !nav.showResults }
        if nav.showResults {
            log("einstellungen-suche: enter kommt nicht an – springe direkt")
            if let h = SettingsSearch.shared.search("decks parallel").first { nav.open(h.entry) }
        }
        guard let par = flashed("audio.parallel") else { fail("Zeile Decks parallel nicht hervorgehoben (flash \(nav.flash ?? "-"))") }
        check(content.contains(NSPoint(x: par.midX, y: par.midY)), "Zeile Decks parallel nicht sichtbar (Sprung scrollt nicht): \(par)")

        // Hervorhebung geht nach ~1,5 s weg; ↓ wählt den nächsten Treffer, esc leert die Suche
        u.spin(3) { nav.flash == nil }
        check(nav.flash == nil, "Hervorhebung bleibt stehen")
        func key(_ chars: String, _ code: UInt16) {
            guard let field, w.makeFirstResponder(field),
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
            w.sendEvent(e)
            u.spin(0.2)
        }
        type("loop")
        key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
        if nav.selected != 1 { log("einstellungen-suche: ↓ kommt nicht an (synthetisch), gewählt \(nav.selected)") }
        key("\u{1b}", 53)
        u.spin(0.5) { nav.query.isEmpty }
        if !nav.query.isEmpty { log("einstellungen-suche: esc kommt nicht an (synthetisch)"); nav.query = "" }
        // Sprung aus der Effekt-Auswahl (gesperrtes Plugin): Bereich PLUGINS, eine stehende Suche geht weg
        type("reverb")
        u.mix.settingsRequest = "PLUGINS"
        u.spin(3) { nav.tab == "PLUGINS" && u.mix.settingsRequest == nil }   // unter Last (Load > 40) braucht der Umschalt-Durchlauf > 1 s
        check(nav.tab == "PLUGINS" && nav.query.isEmpty && !nav.showResults && u.mix.settingsRequest == nil,
              "settingsRequest: Bereich \(nav.tab), Suche „\(nav.query)“, Anfrage \(u.mix.settingsRequest ?? "-")")
        log(String(format: "einstellungen-suche: puffer -> AUDIO y %.0f · decks parallel -> y %.0f (fenster %.0f)", buf.midY, par.midY, size.height))
    }
}

extension UISelfTest {
    /// Insert-Slots an FX 1: „+“ im Kopf der Unit -> Effekt-Auswahl -> DELAY, noch einmal -> AULowpass (Apple), Rechtsklick auf
    /// Slot 2 -> „Slot entfernen“. Die Zeilen erscheinen bzw. verschwinden in der Leiste. Kommen synthetische Klicks in der
    /// Effekt-Auswahl (eigenes Popover-Fenster) nicht an: Direktaktion (steht im Log). Danach FX 1 wie vorher
    static func insertSlots(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, b = 0
        let saved = mix.fxUnits[b].state.slots
        mix.core.setSlots(b, [])
        defer { mix.core.setSlots(b, saved); u.spin(0.3) }
        u.spin(0.4)
        func popovers() -> [NSWindow] { NSApp.windows.filter { $0 !== u.window && String(describing: type(of: $0)).contains("Popover") && $0.isVisible } }
        func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
        func mark(_ name: String, in w: NSWindow) -> UITestMark.V? {
            guard let root = w.contentView?.superview ?? w.contentView else { return nil }
            return allViews(root).compactMap { $0 as? UITestMark.V }.first { $0.name == name }
        }
        func row(_ k: Int, _ id: String) -> UITestMark.V? { mark("fx slot \(b) \(k) \(id)", in: u.window) }
        func closePopovers() { for w in popovers() { w.orderOut(nil) }; u.spin(0.2) }
        func click(_ v: NSView, in w: NSWindow) {
            let r = v.convert(v.bounds, to: nil), p = NSPoint(x: r.midX, y: r.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
                w.sendEvent(e)
            }
        }
        /// + klicken, im Popover den Effekt wählen
        func add(_ id: String) {
            let before = mix.slots(b).count
            guard let plus = mark("fx add \(b)", in: u.window) else { fail("„+“ an FX 1 nicht gefunden") }
            u.click(at: u.center(plus))
            u.spin(1.5) { popovers().contains { mark("pick \(id)", in: $0) != nil } }
            if let w = popovers().first(where: { mark("pick \(id)", in: $0) != nil }), let m = mark("pick \(id)", in: w) {
                m.superview?.scrollToVisible(m.frame)   // Plugins stehen weiter unten in der Liste
                u.spin(0.3)
                click(m, in: w)
                u.spin(1) { mix.slots(b).count > before }
                log("insert-slots: \(id) \(mix.slots(b).count > before ? "über die Effekt-Auswahl" : "– Klick in der Auswahl kommt nicht an")")
            } else {
                log("insert-slots: Effekt-Auswahl öffnet nicht auf den synthetischen Klick")
            }
            closePopovers()
            if mix.slots(b).count == before {
                log("insert-slots: \(id) per Direktaktion")
                mix.addSlot(b, id)
            }
        }
        add("DELAY")
        u.spin(1) { row(0, "DELAY") != nil }
        check(mix.slots(b).map(\.id) == ["DELAY"], "nach + DELAY: \(mix.slots(b).map(\.id))")
        check(row(0, "DELAY") != nil, "Zeile 1 DELAY fehlt in der Leiste")
        let plug = "aufx:lpas:appl"
        add(plug)
        u.spin(10) { mix.core.pluginInstance(b, slot: 1) != nil && row(1, plug) != nil }
        check(mix.slots(b).map(\.id) == ["DELAY", plug], "nach + AULowpass: \(mix.slots(b).map(\.id))")
        check(mix.core.pluginInstance(b, slot: 1) != nil, "AULowpass lädt nicht: \(mix.pluginError(b) ?? "-")")
        check(row(1, plug) != nil, "Zeile 2 AULowpass fehlt in der Leiste")
        // EDIT: an dem Plugin-Slot, nicht am eingebauten; öffnet das Plugin-Fenster (kommt der Klick nicht an: Direktaktion)
        check(mark("fx edit \(b) 0", in: u.window) == nil, "EDIT an eingebautem Effekt DELAY")
        if let edit = mark("fx edit \(b) 1", in: u.window) {
            func pluginWindows() -> [NSWindow] { NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("◆ PLUGIN") } }
            u.click(at: u.center(edit))
            u.spin(2) { !pluginWindows().isEmpty }
            if pluginWindows().isEmpty { log("insert-slots: EDIT kommt nicht an (synthetisch) – öffne direkt"); PluginWindow.show(unit: b, slot: 1, core: mix.core) }
            check(!pluginWindows().isEmpty, "EDIT öffnet kein Plugin-Fenster")
            pluginWindows().forEach { $0.close() }
            u.spin(0.5)
        } else {
            fail("EDIT an Plugin-Slot 2 fehlt in der Leiste")
        }
        // ✕ über das Kontextmenü der Zeile
        let item = String(localized: "Slot entfernen")
        if let r = row(1, plug), let menu = u.rightClick(at: u.center(r)), let i = menu.items.firstIndex(where: { $0.title == item }) {
            menu.performActionForItem(at: i)
        } else {
            log("insert-slots: kein Kontextmenü an Slot 2 – entferne per Direktaktion")
            mix.removeSlot(b, slot: 1)
        }
        u.spin(1) { row(1, plug) == nil }
        check(mix.slots(b).map(\.id) == ["DELAY"] && row(1, plug) == nil, "nach ✕: \(mix.slots(b).map(\.id))")
        log("insert-slots: \(mix.slots(b).map(\.id)) · Zeilen in der Leiste ok")
    }
}

extension UISelfTest {
    /// Zeilen zweizeilig in Bereich A: Klick auf ≡ im Kopf -> Sammelspalte „Track“ statt Titel/Artist/…, Detailleiste da;
    /// Pfeil runter in der Tabelle -> Detailleiste zeigt den nächsten Track; Klick auf einen Tag-Chip in Zeile 2 der
    /// Sammelspalte -> Tag-Filter aktiv. Kommt ein synthetischer Klick nicht an: Direktaktion (steht im Log)
    static func twoLineRows(_ u: UIDriver, _ t: [Track]) {
        let pane = u.browser.paneA, mix = u.mix
        let two0 = pane.twoLine, detail0 = pane.detailBar, source0 = pane.source, rows0 = mix.prefs.ui.browserRows, bar0 = mix.prefs.ui.detailBar
        defer { pane.clearTags(); pane.twoLine = two0; pane.detailBar = detail0; pane.source = source0; pane.selection = []; u.spin(0.5) }
        mix.prefs.ui.browserRows = .single
        mix.prefs.ui.detailBar = .auto
        pane.twoLine = nil
        pane.detailBar = nil
        pane.clearTags()
        pane.source = .collection
        u.spin(5) { !pane.listPending && !pane.shown.isEmpty }
        func table() -> NSTableView? {
            u.views.compactMap { $0 as? TrackHeaderView }.first { h in
                guard let tv = h.tableView else { return false }
                return tv.numberOfRows == pane.shown.count && u.frame(h).minX < u.window.frame.width / 2
            }?.tableView
        }
        guard let mark = u.views.compactMap({ $0 as? UITestMark.V }).filter({ $0.name == "rows A" }).first else { fail("Symbol ≡ im Kopf von A fehlt") }
        let r = u.frame(mark), p = NSPoint(x: r.midX, y: r.midY)
        u.click(at: p)   // Loslassen liegt vorab beim Fenster (Knopf verfolgt die Maus)
        u.spin(1) { pane.twoLine == true }
        if pane.twoLine != true { log("zweizeilig: klick auf ≡ kommt nicht an – schalte direkt"); pane.twoLine = true }
        u.spin(3) { table()?.tableColumns.first { $0.identifier.rawValue == "track" }?.isHidden == false && pane.detail != nil }
        guard let tv = table(), let ctl = tv.delegate as? TrackTableController else { fail("zweizeilig: Tabelle von A fehlt") }
        let track = tv.tableColumns.first { $0.identifier.rawValue == "track" }
        check(track?.isHidden == false && tv.tableColumns.first { $0.identifier.rawValue == "title" }?.isHidden == true, "zweizeilig: keine Sammelspalte")
        check(tv.rowHeight == TableStyle.rowHeight(mix.prefs.ui, twoText: true), "zweizeilig: Zeilenhöhe \(tv.rowHeight)")
        guard let bar = pane.detail else { fail("zweizeilig: Detailleiste fehlt") }
        // Pfeil runter in der Tabelle
        pane.selection = [pane.shown[0].key]
        u.spin(0.3)
        u.window.makeFirstResponder(tv)
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: u.window.windowNumber,
                                    context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) {
            tv.keyDown(with: e)
        }
        u.spin(1) { bar.track?.key == pane.shown[1].key }
        check(pane.selection == [pane.shown[1].key], "Pfeil runter: Auswahl \(pane.selection.count)")
        check(bar.track?.key == pane.shown[1].key, "Detailleiste zeigt nicht den neuen Track: \(bar.track?.title ?? "-")")
        // Tag-Chip in Zeile 2 der Sammelspalte (Liste bis zu einem Track mit Tags gescrollt; Zeilen der Tabelle)
        u.spin(3) { !pane.listPending && ctl.shownRows.count == pane.shown.count }
        let rows = ctl.shownRows
        if let i = rows.firstIndex(where: { !BrowserPaneModel.tags(of: $0, separators: mix.prefs.ui.tagSeparators).isEmpty }) {
            tv.scrollRowToVisible(min(rows.count - 1, i + 3))
            tv.scrollRowToVisible(i)
            u.spin(0.3)
        }
        let vis = tv.rows(in: tv.visibleRect)
        guard let ti = tv.tableColumns.firstIndex(where: { $0 === track }) else { fail("zweizeilig: Spalte Track") }
        var target: (NSPoint, String)?
        for row in vis.location..<min(rows.count, vis.location + vis.length) {
            let f = tv.frameOfCell(atColumn: ti, row: row)
            guard let box = ctl.trackLayout(rows[row], f).first(where: { $0.part == .tags }) else { continue }
            let pt = NSPoint(x: box.rect.minX + 4, y: box.rect.midY)
            if let tag = ctl.trackHit(row: row, column: ti, at: pt)?.tag { target = (pt, tag); break }
        }
        guard let (pt, tag) = target else {
            let cand = (vis.location..<min(rows.count, vis.location + vis.length)).map { row -> String in
                let b = ctl.trackLayout(rows[row], tv.frameOfCell(atColumn: ti, row: row))
                return "\(row): " + b.map { "\($0.part.rawValue) \(Int($0.rect.width))" }.joined(separator: ",")
            }
            fail("zweizeilig: keine sichtbare Zeile mit Tags (\(vis), breite \(Int(track?.width ?? 0)), sort \(pane.sortOrder.map { "\($0.keyPath)" }), quelle \(pane.source.title)) " + cand.prefix(4).joined(separator: " | "))
        }
        u.click(at: tv.convert(pt, to: nil), viaApp: true)
        u.spin(1) { !pane.tagFilter.isEmpty }
        if pane.tagFilter.isEmpty { log("zweizeilig: klick auf den chip kommt nicht an – filtere direkt"); pane.toggleTag(tag, exclude: false) }
        check(pane.tags.contains(tag), "Tag-Chip „\(tag)“: Filter \(pane.tags)")
        u.spin(3) { !pane.listPending }
        log("zweizeilig: zeile \(tv.rowHeight) pt, detailleiste \(bar.track?.title ?? "-"), tag „\(tag)“ -> \(pane.shown.count) tracks")
        mix.prefs.ui.browserRows = rows0
        mix.prefs.ui.detailBar = bar0
    }
}

extension UISelfTest {
    /// Trenner Decks/Browser in Schritten ziehen (nach oben, Fensterkoordinaten): die Browser-Höhe steigt in jedem Schritt
    /// ohne Umkehr (vorher zitterte sie, weil der Griff mit der Höhe wanderte), gespeichert wird erst beim Loslassen
    static func splitDrag(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, pane = u.browser.paneA
        var h0 = mix.prefs.ui.browserHeight
        defer { mix.prefs.ui.browserHeight = h0; u.spin(0.3) }
        u.mix.pull()
        guard let grip = u.named("split handle") else { fail("Trenner fehlt") }
        // Aufwärmen (nicht gemessen): ein Zug über den ganzen Bereich hoch und zurück; danach sind die Zeilen bis dahin
        // einmal aufgebaut (sonst fällt der Erstaufbau neuer Zeilen in die Messung, nicht der Dauerbetrieb)
        var w = u.center(grip)
        u.drag(from: w, to: NSPoint(x: w.x, y: w.y + 120), steps: 40)
        w = u.center(grip)
        u.drag(from: w, to: NSPoint(x: w.x, y: w.y - 120), steps: 40)
        h0 = mix.prefs.ui.browserHeight
        // Messung: 40 Schritte hoch (+120 pt), 40 zurück; je Schritt ein Ziehen-Ereignis, gemessen bis der Hauptthread frei ist
        FrameProbe.install()
        let b0 = WaveLayerNSView.builds
        var seen: [Double] = [Double(u.frame(grip).minY)]
        var savedDuring: [Double] = []
        var ms: [Double] = [], moved: [Double] = []
        let step: () -> Void = {
            let dt = FrameProbe.take()
            ms.append(dt)
            let y = Double(u.frame(grip).minY)   // Trenner folgt der sichtbaren Browser-Höhe
            if y != seen.last { moved.append(dt) }   // Schritte, die die Höhe ändern
            FrameProbe.begin()
            seen.append(y)
            savedDuring.append(mix.prefs.ui.browserHeight)
        }
        let c = u.center(grip)
        FrameProbe.begin()
        u.drag(from: c, to: NSPoint(x: c.x, y: c.y + 120), steps: 40, each: step)
        let up = ms.count
        let upMs = Array(ms.prefix(up))
        let hMid = mix.prefs.ui.browserHeight   // nach dem ersten Loslassen: eingerastet und gespeichert
        let c2 = u.center(grip)
        u.drag(from: c2, to: NSPoint(x: c2.x, y: c2.y - 120), steps: 40, each: step)
        // nach dem Loslassen: Einrasten und das Deck-Layout nach kurzer Übergangszeit (unter Last später)
        u.spin(3) { abs(mix.prefs.ui.browserHeight - Double(pane.paneHeight)) < 1.5 }
        let b1 = WaveLayerNSView.builds
        let h1 = mix.prefs.ui.browserHeight
        log("trenner hoch: \(FrameProbe.summary(upMs))")
        log("trenner zurück: \(FrameProbe.summary(Array(ms.dropFirst(up))))")
        log("trenner, Schritte mit Höhenänderung: \(FrameProbe.summary(moved))")
        log("trenner: wellenform-aufbau \(b1.rebuild - b0.rebuild)× · gitter \(b1.grid - b0.grid)× · kacheln leeren \(b1.tiles - b0.tiles)×")
        log("trenner: \(seen.map { Int($0) }) · gespeichert \(h0) → \(hMid) → \(h1)")
        let forth = Array(seen.prefix(up + 1)), back = Array(seen.dropFirst(up + 1))
        check(seen[up] > seen[0] + 100, "Browser wächst nicht: \(seen[0]) → \(seen[up])")
        check(zip(forth, forth.dropFirst()).allSatisfy { $1 >= $0 - 0.5 }, "Höhe springt beim Ziehen: \(seen.map { Int($0) })")
        check(zip(back, back.dropFirst()).allSatisfy { $1 <= $0 + 0.5 }, "Höhe springt beim Zurückziehen: \(seen.map { Int($0) })")
        check(savedDuring.prefix(up).allSatisfy { $0 == h0 }, "Höhe während des Ziehens gespeichert: \(savedDuring)")
        check(savedDuring.dropFirst(up).allSatisfy { $0 == hMid }, "Höhe während des Zurückziehens gespeichert: \(savedDuring)")
        check(abs(h1 - Double(pane.paneHeight)) < 1.5, "gespeicherte Höhe \(h1) ≠ Browser \(pane.paneHeight)")
    }
}
