import AppKit
import AVFoundation
import Foundation
import QuartzCore
import UniformTypeIdentifiers
import MixCore
import MixEngine

/// Stummer Selbsttest (MIX741_SELFTEST=1): lädt zwei Tracks, spielt A, synct B, prüft Loop/Beatjump/FX
/// und dass Audio + Sync weiterlaufen, während der Hauptthread blockiert ist.
@MainActor
enum SelfTest {
    /// aus: Messungen mit der ganzen Oberfläche (ZoomShot), die Decks bleiben, wie sie sind
    static var enabled = true

    static func run(store: LibraryStore, mix: MixModel, browser: BrowserState) {
        guard enabled, ProcessInfo.processInfo.environment["MIX741_SELFTEST"] == "1" else { return }
        let core = mix.core
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            for _ in 0..<20 where mix.outputDevices.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            core.engine.deviceRate = nil   // Geräterate nie umstellen (ein anderes MINOS könnte gerade darauf spielen)
            let named = env["MIX741_OUT"].flatMap { n in mix.outputDevices.first { $0.channels >= 8 && $0.name.localizedCaseInsensitiveContains(n) } }
            if env["MIX741_NOEXT"] == nil, let ext = named ?? mix.outputDevices.first(where: { $0.channels >= 8 }) {   // externes Interface, jedes Deck auf ein eigenes Paar
                core.engine.apply(.init(device: ext.id, firstChannel: [0, 2, 4, 6]))
                log("Routing \(ext.name) extern: läuft=\(core.engine.running) Fehler=\(core.engine.lastError ?? "keine")")
            } else if let dev = mix.outputDevices.first(where: { d in env["MIX741_OUT"].map { d.name.localizedCaseInsensitiveContains($0) } ?? false })
                        ?? mix.outputDevices.first(where: { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") })
                        ?? mix.outputDevices.first(where: { $0.channels < 8 }) {
                // MIX741_NOEXT: nie auf das Interface einer laufenden Live-Session, sondern auf ein eingebautes
                // 2-Kanal-Gerät (MIX741_OUT=<Name> wählt eines); Master-Volume 0 -> stumm
                core.engine.apply(.init(device: dev.id, firstChannel: [0, 0, 0, 0]))
                log("Routing \(dev.name) (Selbsttest, stumm): läuft=\(core.engine.running) Fehler=\(core.engine.lastError ?? "keine")")
            }
            core.engine.setMasterVolume(0)   // stumm, Einstellung bleibt unverändert
            log("Audio: Gerät \(core.engine.outputRate) Hz, Kern \(core.engine.sampleRate) Hz, Raten \(MixEngine.availableRates(mix.currentDevice?.id ?? MixEngine.defaultOutputDevice() ?? 0))")
            // Link nur auf Wunsch (sonst würde der Test das Tempo einer laufenden Link-Session ändern)
            core.setLinkEnabled(ProcessInfo.processInfo.environment["MIX741_LINKTEST"] != nil)
            var p = mix.prefs.engine
            p.historyThreshold = 3            // nur im Test: schnell als gespielt markieren (nicht gespeichert)
            p.phraseAnchor = .suggest         // nur vorschlagen: der Test verschiebt keinen Anker (keine eigenen Änderungen)
            p.autoLoopBars = 16
            core.setPrefs(p)
            while store.tracks.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            if env["MIX741_BENCH"] == "memory" { await memoryProbe(core, tracks: store.tracks); exit(0) }
            if env["MIX741_BENCH"] == "loadtest" { await LoadTest.run(core, tracks: store.tracks); exit(0) }
            if env["MIX741_BENCH"] == "parallel-restart" { await parallelRestartBench(core, tracks: store.tracks) }
            let c = store.tracks.filter { $0.bpm > 120 && $0.bpm < 140 && $0.gridAnchorMs != nil && $0.fileExists }
            guard c.count >= 2 else { log("zu wenige Tracks"); exit(1) }
            log("A: \(c[0].artist) – \(c[0].title) \(c[0].bpm) · B: \(c[1].artist) – \(c[1].title) \(c[1].bpm)")
            core.load(c[0], deck: 0)
            core.load(c[1], deck: 1)
            while core.trackAudio(0) == nil || core.trackAudio(1) == nil {
                let s = core.snapshot()
                if let e = s.decks[0].error ?? s.decks[1].error { log(e); exit(1) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Phrasen-Anker läuft nach dem Laden im Hintergrund (Vorschlag oder keiner)
            try? await Task.sleep(for: .milliseconds(800))
            for d in 0..<2 {
                let s = core.snapshot().decks[d]
                log(String(format: "Phrasen-Anker %@: %@", deckLetters[d], s.phraseSuggestion.map { String(format: "%+d Beats (Sicherheit %.2f)", $0, s.phraseConfidence) } ?? "kein Vorschlag"))
            }
            autoLoopCheck(core)
            // nur Bild: beide Decks auf 1:00 stellen, nicht abspielen, kurz stehen lassen (für Screenshots)
            if ProcessInfo.processInfo.environment["MIX741_SNAPSHOT"] != nil {
                core.seek(0, seconds: 60); core.seek(1, seconds: 60)
                try? await Task.sleep(for: .seconds(2))
                log("SNAPSHOT bereit")
                try? await Task.sleep(for: .seconds(8))
                exit(0)
            }
            core.togglePlay(0)
            try? await Task.sleep(for: .seconds(2))
            log(String(format: "A läuft: Position %.2f s", core.position(0)))
            core.toggleSync(1)
            core.togglePlay(1)
            try? await Task.sleep(for: .seconds(3))
            log(String(format: "B %.2f BPM vs Master %.2f · Phase %.4f Beats",
                       core.snapshot().decks[1].bpm, core.snapshot().decks[0].bpm, core.phaseError(1) ?? .nan))
            // Hauptthread 3 s blockieren: Audio und Sync müssen weiterlaufen
            let p0 = core.position(0)
            core.setTempo(0, 3)
            Thread.sleep(forTimeInterval: 3)
            log(String(format: "Hauptthread 3 s blockiert: A lief %.2f s weiter, B folgt %.2f BPM, Phase %.4f",
                       core.position(0) - p0, core.snapshot().decks[1].bpm, core.phaseError(1) ?? .nan))
            // Master-Clock: MINOS gibt das Tempo vor, B (Sync) folgt Tempo und Phase der Clock
            core.setClockMaster(true)
            core.setClockBPM(126)
            try? await Task.sleep(for: .seconds(3))
            log(String(format: "Clock-Master 126: B %.2f BPM, Phase zur Clock %.4f Beats, Clock-Beat %.2f",
                       core.snapshot().decks[1].bpm, core.phaseError(1) ?? .nan, core.engine.clockBeat))
            await linkDryRun(core)
            core.setClockMaster(false)
            // Semi-Sync-Start: B ungesynct stoppen und neu starten, A ist Master -> B springt beim Start in Phase,
            // Tempo (von Sync übernommen) und Sync-Zustand bleiben; danach wieder Sync wie zuvor
            try? await Task.sleep(for: .milliseconds(300))   // Sync zieht B erst wieder auf A nach
            core.toggleSync(1)
            core.togglePlay(1)
            try? await Task.sleep(for: .milliseconds(300))
            core.setSemiSync(true)
            let semiTempo = core.snapshot().decks[1].tempoPct, semiBefore = core.phaseError(1) ?? .nan
            core.togglePlay(1)
            try? await Task.sleep(for: .seconds(1))
            let sB = core.snapshot().decks[1]
            log(String(format: "Semi-Start B ungesynct (A Master): Phase vor Start %.4f, nach 1 s %.4f Beats (soll < 0.05) · B %.2f vs A %.2f BPM · Tempo %.2f -> %.2f %% · Sync %@",
                       semiBefore, core.phaseError(1) ?? .nan, sB.bpm, core.snapshot().decks[0].bpm, semiTempo, sB.tempoPct, "\(sB.sync)"))
            core.setSemiSync(false)
            core.toggleSync(1)
            core.autoLoop(0, size: 4)
            try? await Task.sleep(for: .seconds(4))
            let l = core.engine.loop(0), pos = core.position(0)
            log("Loop aktiv laut Engine: \(l.active), laut Kern: \(core.snapshot().decks[0].loopActive)")
            log(String(format: "Loop A %.2f–%.2f, Position %.2f, im Loop: %@", l.start, l.end, pos,
                       "\(pos >= l.start - 0.01 && pos <= l.end + 0.01)"))
            // Takt-Sprung im 8-Beat-Loop: Loop bleibt, Position +4 Beats (umlaufend)
            core.exitLoop(0)
            core.autoLoop(0, size: 8)
            try? await Task.sleep(for: .milliseconds(300))
            let l8 = core.engine.loop(0), q0 = core.position(0), t0 = Date()
            let ph0 = core.phaseError(1) ?? .nan
            core.barJump(0, bars: 1)
            try? await Task.sleep(for: .milliseconds(50))
            let l8b = core.engine.loop(0), q1 = core.position(0), len = l8.end - l8.start
            let rate = core.snapshot().decks[0].bpm / 130.000473   // Wiedergabe-Rate, abgelaufene Zeit abziehen
            var moved = (q1 - q0 - Date().timeIntervalSince(t0) * rate).truncatingRemainder(dividingBy: len); if moved < 0 { moved += len }
            log(String(format: "Phase B vor/nach Takt-Sprung: %.4f / %.4f Beats", ph0, core.phaseError(1) ?? .nan))
            log(String(format: "Takt-Sprung im Loop: Loop gleich %@, Versatz %.3f von %.3f Beats (soll 4)",
                       "\(abs(l8b.start - l8.start) < 0.001)", moved / len * 8, 8.0))
            core.exitLoop(0)
            let before = core.position(0)
            core.beatjump(0, beats: 16)
            try? await Task.sleep(for: .milliseconds(100))
            log(String(format: "Beatjump +16: %.2f → %.2f", before, core.position(0)))
            // FX messen: Pegel am Kanal A ohne Effekt, mit Filter (Highpass zu), mit Reverb
            func level() async -> Float {
                var acc: Float = 0
                for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(50)); acc += core.engine.levels[0].rms }
                return acc / 20
            }
            log("FX-Zuweisung A: \(core.snapshot().decks[0].fxAssign)")
            let dry = await level()
            // FX 1: Vorlage Gruppe (Filter · Delay · Reverb)
            core.updateFX(0) { $0.slots[0].on = true; $0.slots[0].params["cutoff"] = 1.0 }
            let hp = await level()
            core.updateFX(0) { $0.slots[0].on = false; $0.slots[2].on = true; $0.slots[2].mix = 1.0 }
            let rev = await level()
            core.updateFX(0) { $0.slots[2].on = false }
            // FX 3 mit einem Slot (Delay) auf Deck A
            core.toggleFXAssign(0, 2)
            core.updateFX(2) { $0.slots = [FXSlot(id: "DELAY", on: true, params: ["filter": 0.5, "feedback": 0.7, "rate": 0.5])] }
            try? await Task.sleep(for: .seconds(1))
            core.togglePlay(0)                       // Deck stoppen: hörbar bleibt nur noch die Echo-Fahne
            try? await Task.sleep(for: .milliseconds(150))
            let tail = await level()
            core.updateFX(2) { $0.slots[0].on = false }   // aus: Eingang zu, Echo muss weiter ausklingen
            try? await Task.sleep(for: .milliseconds(200))
            let spill = await level()
            try? await Task.sleep(for: .seconds(4))
            let gone = await level()
            core.toggleFXAssign(0, 2)
            log(String(format: "FX3 Single-Delay: Echo nach Stopp %.3f (ohne Delay ~0)", tail))
            log(String(format: "FX3 aus: Echo klingt aus %.3f, nach 4 s %.4f", spill, gone))
            // Reverb (FX4 Single): D/W 0 = trocken unverändert, D/W hoch = Hall aus den Höhen dazu, aus = klingt lange aus
            core.togglePlay(0)
            core.toggleFXAssign(0, 3)
            core.updateFX(3) { $0.slots = [FXSlot(id: "REVERB", on: true, params: ["size": 0.9, "hp": 0.75, "lp": 1.0, "send": 1])]
                               $0.dryWet = 0 }
            let rDry = await level()
            core.updateFX(3) { $0.dryWet = 1 }
            try? await Task.sleep(for: .seconds(2))
            let rWet = await level()
            core.updateFX(3) { $0.dryWet = 0 }       // Drop: nichts Neues mehr in den Hall
            core.togglePlay(0)
            try? await Task.sleep(for: .seconds(1))
            let r1 = await level()
            try? await Task.sleep(for: .seconds(3))
            let r4 = await level()
            core.updateFX(3) { $0.slots[0].on = false }
            core.toggleFXAssign(0, 3)
            log(String(format: "Reverb Single HP: D/W 0 %.3f (trocken %.3f) · D/W 1 %.3f · nach Drop 1 s %.4f · 4 s %.4f",
                       rDry, dry, rWet, r1, r4))
            core.togglePlay(0)
            // Beat-FX (FX3 Single) auf Deck A: Pegel an / nach dem Ausschalten (Roll: Deck läuft darunter weiter)
            core.toggleFXAssign(0, 2)
            for e in FXCatalog.beatFX {
                core.updateFX(2) { var s = FXTemplate.slot(e.name); s.on = true; $0.slots = [s]; $0.dryWet = 1 }
                let on = await level()
                core.updateFX(2) { $0.slots[0].on = false }
                let off = await level()
                log(String(format: "%@ Single: an %.3f · aus %.3f (trocken %.3f)", e.name, on, off, dry))
            }
            core.toggleFXAssign(0, 2)
            // Plugin (FX4 Single): Apples AUMatrixReverb, lädt im Hintergrund, Regler = erste 3 Parameter, Fahne nach Stopp
            core.toggleFXAssign(0, 3)
            core.setSlots(3, [FXSlot(id: "aufx:mrev:appl")])
            for _ in 0..<60 where core.pluginParamNames(3).isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            core.updateFX(3) { $0.slots[0].on = true; $0.dryWet = 0.5 }
            try? await Task.sleep(for: .seconds(1))
            let pWet = await level()
            core.updateFX(3) { $0.slots[0].on = false }
            core.togglePlay(0)
            try? await Task.sleep(for: .milliseconds(150))
            let pTail = await level()
            let pNames = core.pluginParamNames(3).joined(separator: "/"), pErr = core.snapshot().pluginErrors[3]
            core.setSlots(3, [])
            core.toggleFXAssign(0, 3)
            core.togglePlay(0)
            log(String(format: "Plugin %@: Regler %@ · D/W 0.5 %.3f · Fahne nach Stopp %.4f%@",
                       "aufx:mrev:appl", pNames, pWet, pTail, pErr.map { " · Fehler: \($0)" } ?? ""))
            log(String(format: "Pegel A: trocken %.3f · Filter HP %.3f (%.0f %%) · Reverb %.3f (%.0f %%)",
                       dry, hp, hp / max(dry, 1e-6) * 100, rev, rev / max(dry, 1e-6) * 100))
            await deviceProbe(core)
            await parallelProbe(core)
            if await !parallelRestartProbe(core) { log("FEHLER Decks parallel: Ausgabe nach Neustart"); exit(1) }
            await chainProbe(mix, tracks: c)
            await insertProbe(mix)
            await eqProbe(mix)
            guard await autoMixProbe(mix, tracks: c) else { log("FEHLER Auto-Mix"); exit(1) }
            await previewProbe(mix, tracks: c)
            await cutProbe(mix, tracks: c)
            await editProbe(mix)
            await profileProbe(mix, browser: browser)
            await undoProbe(mix, store: store)
            await grooveProbe(mix)
            await nmlProbe()
            await dawBridgeProbe(mix, store: store)
            await hidePlayedProbe(mix, store: store, browser: browser, tracks: c)
            detailBarProbe(mix, store: store)
            await prepareProbe(mix)
            await playlistTreeProbe(store: store)
            await wavePresetProbe(mix)
            await recordProbe(mix, tracks: c)
            waveTileProbe(mix)
            ledShowProbe()
            settingsSearchProbe()
            await ripProbe(mix, tracks: c)
            if env["MIX741_BENCH"] == "load" { await loadProbe(core, tracks: c) }
            // nur die eigene Test-History entfernen (Datei dieser Sitzung), nichts anderes anfassen
            if ProcessInfo.processInfo.environment["MIX741_KEEP_HISTORY"] == nil, let url = SelfTest.historyURL {
                try? FileManager.default.removeItem(at: url)
                log("Test-History entfernt: \(url.lastPathComponent)")
            }
            log("SELFTEST OK")
            fflush(stdout)
            if ProcessInfo.processInfo.environment["MIX741_STAY"] == nil { exit(0) }
        }
    }

    /// Ansichts-Profile: die zwei Standard-Profile nacheinander anwenden, Felder und sichtbare Decks prüfen,
    /// Umschaltzeit (Felder setzen + Layout des Hauptfensters + Übergabe an Core Animation) messen, danach zurück
    static func profileProbe(_ mix: MixModel, browser: BrowserState) async {
        let savedUI = mix.prefs.ui, savedBig = browser.maximized, savedFocus = mix.focusedDeck
        let root = MainWindow.window?.contentView
        func decks() -> [Int] {
            var out: [Int] = [], stack = root.map { [$0] } ?? []
            while let v = stack.popLast() {
                if let h = v as? BoundaryHostingView<DeckHost.Root>, !h.isHiddenOrHasHiddenAncestor { out.append(h.rootView.d) }
                stack += v.subviews
            }
            return out.sorted()
        }
        var times: [Double] = []
        for round in 0..<3 {
            for p in LayoutProfile.defaults(from: savedUI) {
                mix.focusedDeck = 1
                let t0 = CACurrentMediaTime()
                LayoutProfiles.apply(p, mix: mix, browser: browser)
                root?.layoutSubtreeIfNeeded()
                CATransaction.flush()
                let dt = (CACurrentMediaTime() - t0) * 1000
                if round > 0 { times.append(dt) }   // erste Runde: Aufwärmen
                try? await Task.sleep(for: .milliseconds(150))
                let ui = mix.prefs.ui, shown = decks()
                let want = Array([0, 1, 2, 3].prefix(p.deckCount >= 4 ? 4 : p.deckCount))
                let ok = p.matches(ui, maximized: browser.maximized) && ui.activeProfile?.id == p.id
                    && !ui.profileModified(maximized: browser.maximized) && (root == nil || shown == want)
                    && (p.deckCount > 1 || mix.focusedDeck == 0)   // 1 Deck: Fokus auf A
                if round == 0 {
                    log(String(format: "Profil %@: %d Decks (sichtbar %@), Mixer %@, Browser %@ %.0f pt, Statusleiste %@ · %.1f ms",
                               p.name, ui.deckCount, root == nil ? "kein Fenster" : shown.map { deckLetters[$0] }.joined(),
                               "\(ui.showMixer)", ui.browserLayout.rawValue, ui.browserHeight, ui.statusBar.rawValue, dt))
                }
                guard ok else { log("FEHLER Profil \(p.name): Felder oder Decks stimmen nicht (sichtbar \(shown))"); exit(1) }
            }
        }
        // Änderung nach dem Umschalten -> „geändert“, Profil bleibt aktiv
        mix.prefs.ui.showMixer.toggle()
        let changed = mix.prefs.ui.profileModified(maximized: browser.maximized) && mix.prefs.ui.activeProfile != nil
        mix.prefs.ui = savedUI
        browser.maximized = savedBig
        mix.focusedDeck = savedFocus
        let s = times.sorted()
        log(String(format: "Profil umschalten (Hauptthread, Felder + Layout + Übergabe): median %.1f ms, max %.1f ms (n=%d) · Änderung erkannt %@",
                   s.isEmpty ? .nan : s[s.count / 2], s.last ?? .nan, s.count, "\(changed)"))
        guard changed else { log("FEHLER Profil: Änderung nicht erkannt"); exit(1) }
    }

    /// Geräte-Pfade ohne Ziehen/Stecken: Gerät weg (eingespeist) -> warten -> dasselbe Gerät neu öffnen, Ratenwechsel
    /// (eingespeist, Geräterate bleibt), Puffer am Gerät geändert (echter Listener), Ruhezustand/Aufwachen. Deck A spielt
    /// dabei weiter (Position läuft nach jedem Schritt)
    static func deviceProbe(_ core: MixController) async {
        let engine = core.engine
        let wasPlaying = core.snapshot().decks[0].playing
        if !wasPlaying { core.togglePlay(0) }
        func waitRunning() async -> Double {
            let t0 = Date()
            for _ in 0..<60 where engine.watch.phase != .running { try? await Task.sleep(for: .milliseconds(50)) }
            return Date().timeIntervalSince(t0)
        }
        func advancing() async -> Bool {
            let p0 = core.position(0)
            try? await Task.sleep(for: .milliseconds(300))
            return core.position(0) > p0 + 0.1
        }
        let n0 = engine.watch.reconnects
        engine.simulate(.alive(false))
        let lost = engine.watch.phase, stopped = !engine.running
        let back = await waitRunning()
        log(String(format: "Gerät weg (eingespeist): %@, Ausgabe aus %@ -> wieder verbunden nach %.0f ms (Öffnen %.0f ms), Neuverbindungen %d, A läuft %@",
                   lost.rawValue, "\(stopped)", back * 1000, (engine.lastReconnect ?? .nan) * 1000, engine.watch.reconnects - n0,
                   "\(await advancing())"))
        let rate = engine.outputRate
        engine.simulate(.rate(rate + 1000))
        let rr = await waitRunning()
        log(String(format: "Ratenwechsel (eingespeist): neu geöffnet nach %.0f ms, Gerät %.0f Hz (unverändert %@), Kern %.0f Hz, A läuft %@",
                   rr * 1000, engine.outputRate, "\(engine.outputRate == rate)", engine.sampleRate, "\(await advancing())"))
        let buf = engine.takeLoad().bufferFrames, want: UInt32 = buf == 256 ? 512 : 256
        engine.setDeviceBufferForTest(want)
        for _ in 0..<20 where engine.takeLoad().bufferFrames != Int(want) { try? await Task.sleep(for: .milliseconds(50)) }
        let l = engine.takeLoad()
        log(String(format: "Puffer am Gerät %d -> %d: gemeldet %d Frames, Latenz %.1f ms, Pufferwechsel %d, A läuft %@",
                   buf, want, l.bufferFrames, l.outputLatency * 1000, engine.watch.bufferChanges, "\(await advancing())"))
        engine.setDeviceBufferForTest(UInt32(buf))
        try? await Task.sleep(for: .milliseconds(200))
        engine.willSleep()
        let sleeping = engine.watch.phase, quiet = !engine.running, pos = core.position(0)
        try? await Task.sleep(for: .milliseconds(300))
        let frozen = abs(core.position(0) - pos) < 0.01
        engine.didWake()
        let woke = await waitRunning()
        log(String(format: "Ruhezustand: %@, Ausgabe aus %@, Position steht %@ -> aufgewacht, läuft nach %.0f ms, A läuft %@, Deck spielt %@",
                   sleeping.rawValue, "\(quiet)", "\(frozen)", woke * 1000, "\(await advancing())", "\(core.snapshot().decks[0].playing)"))
        if !wasPlaying { core.togglePlay(0) }
    }

    /// Decks parallel am laufenden Gerät: einschalten, Blöcke laufen weiter, keine Überläufe, Position läuft; danach zurück
    static func parallelProbe(_ core: MixController) async {
        let engine = core.engine
        let was = engine.parallelDecks
        let wasPlaying = core.snapshot().decks[0].playing
        if !wasPlaying { core.togglePlay(0) }
        _ = engine.takeLoad()
        engine.resetOverloads()
        engine.parallelDecks = true
        let p0 = core.position(0)
        try? await Task.sleep(for: .milliseconds(600))
        let l = engine.takeLoad()
        let moved = core.position(0) - p0
        let info = engine.parallelInfo
        engine.parallelDecks = was
        try? await Task.sleep(for: .milliseconds(200))
        let l2 = engine.takeLoad()
        let ok = l.blocks > 0 && l.overloads == 0 && moved > 0.4 && l2.blocks > 0 && info.joined == info.workers && info.realtime == info.workers
        log(String(format: "Decks parallel: an -> %d Blöcke, DSP %.1f %% (Spitze %.0f %%), über Budget %d, A lief %.2f s, Worker %d (Workgroup %d, Echtzeit %d); zurück %@ -> %d Blöcke · %@",
                   l.blocks, l.average * 100, l.peak * 100, l.overloads, moved, info.workers, info.joined, info.realtime, "\(was)", l2.blocks,
                   ok ? "OK" : "FAIL"))
        if !ok { log("FEHLER Decks parallel: Ausgabe läuft nicht sauber"); exit(1) }
        if !wasPlaying { core.togglePlay(0) }
    }

    /// MIX741_BENCH=parallel-restart: 4 lokale Tracks mit Keylock spielen, dann `parallelRestartProbe` mit
    /// MIX741_BENCH_N Runden (Standard 20); Ende mit Exit-Code 0/1
    static func parallelRestartBench(_ core: MixController, tracks all: [Track]) async {
        let n = Int(ProcessInfo.processInfo.environment["MIX741_BENCH_N"] ?? "") ?? 20
        let pick = Array(all.filter { $0.bpm > 120 && $0.bpm < 140 && $0.fileExists && OverviewPolicy.fileState(path: $0.path) == .local }.prefix(4))
        guard pick.count == 4 else { log("zu wenige lokale Tracks"); exit(1) }
        for d in 0..<4 { core.load(pick[d], deck: d) }
        for _ in 0..<200 where (0..<4).contains(where: { core.trackAudio($0) == nil }) { try? await Task.sleep(for: .milliseconds(50)) }
        for d in 0..<4 {
            core.updateDeck(d) { $0.keylock = true }
            if !core.snapshot().decks[d].playing { core.togglePlay(d) }
        }
        let ok = await parallelRestartProbe(core, rounds: n)
        log(ok ? "PARALLEL-RESTART OK" : "PARALLEL-RESTART FAIL")
        exit(ok ? 0 : 1)
    }

    /// Decks parallel über Neustarts der Ausgabe: parallel an (wie der Lasttest: kurz vor dem Neustart), dann je Runde
    /// Puffer 512/256/128 per Neustart, eingespeister Ratenwechsel (Neuöffnen), Pufferwechsel am Gerät (neue Periode).
    /// Nach jedem Schritt müssen Blöcke laufen (Render-Zähler, Position A), 0 Fristabläufe, Worker in Workgroup + Echtzeit.
    /// `rounds` Runden (Selbsttest 5; MIX741_BENCH=parallel-restart: MIX741_BENCH_N, Kernrate per MIX741_CORE_RATE)
    static func parallelRestartProbe(_ core: MixController, rounds: Int = 5) async -> Bool {
        let engine = core.engine
        let was = engine.parallelDecks, savedBuffer = engine.bufferFrames
        let wasPlaying = core.snapshot().decks[0].playing
        if !wasPlaying { core.togglePlay(0) }
        let t0 = engine.parallelWatchdog.timeouts
        func waitRunning() async {
            for _ in 0..<60 where engine.watch.phase != .running { try? await Task.sleep(for: .milliseconds(50)) }
        }
        /// läuft die Ausgabe? Render-Zähler und Position A in 400 ms (takeLoad holt die Statusleiste ab)
        func check(_ what: String) async -> Bool {
            let p0 = core.position(0), r0 = engine.renderCount
            try? await Task.sleep(for: .milliseconds(400))
            let blocks = Int(engine.renderCount - r0), moved = core.position(0) - p0, info = engine.parallelInfo
            let wd = engine.parallelWatchdog
            let ok = blocks > 20 && moved > 0.25 && wd.timeouts == t0 && engine.parallelDecks
                && info.joined == info.workers && info.realtime == info.workers
            if !ok {
                log(String(format: "  %@: %d Blöcke in 400 ms, A lief %.2f s, Fristabläufe %d, parallel %@, Worker %d (Workgroup %d, Echtzeit %d)",
                           what, blocks, moved, wd.timeouts - t0, "\(engine.parallelDecks)", info.workers, info.joined, info.realtime))
            }
            return ok
        }
        var ok = true, steps = 0
        let t = Date()
        for r in 0..<rounds where ok {
            for frames: UInt32 in [512, 256, 128] where ok {
                engine.parallelDecks = false
                try? await Task.sleep(for: .milliseconds(30))
                engine.parallelDecks = true                       // Worker starten am laufenden Gerät (alte Workgroup) …
                engine.bufferFrames = frames
                engine.apply(engine.routing, restart: true)       // … und joinen nach dem Neustart die neue
                ok = await check("Runde \(r + 1) Puffer \(frames) Neustart") && ok
                steps += 1
            }
            guard ok else { break }
            engine.simulate(.rate(engine.outputRate + 1000))      // Ratenwechsel: Ausgabe neu geöffnet, Worker joinen neu
            await waitRunning()
            ok = await check("Runde \(r + 1) Ratenwechsel") && ok
            let buf = engine.takeLoad().bufferFrames, want: UInt32 = buf == 256 ? 512 : 256
            engine.setDeviceBufferForTest(want)                   // Puffer am Gerät: neue Periode für die Worker
            for _ in 0..<20 where engine.takeLoad().bufferFrames != Int(want) { try? await Task.sleep(for: .milliseconds(50)) }
            ok = await check("Runde \(r + 1) Puffer am Gerät \(want)") && ok
            steps += 2
        }
        var wd = engine.parallelWatchdog
        // Watchdog am Gerät: Worker B hängt 150 ms -> Block endet in der Frist, ab dann seriell, Ausgabe läuft weiter
        var dogOK = true
        if ok {
            engine.parallelDecks = true
            try? await Task.sleep(for: .milliseconds(100))
            let r0 = engine.renderCount, p0 = core.position(0)
            engine.stallWorkerForTest(0, seconds: 0.15)
            try? await Task.sleep(for: .milliseconds(400))
            let after = engine.parallelWatchdog, blocks = Int(engine.renderCount - r0), moved = core.position(0) - p0
            dogOK = after.timeouts == wd.timeouts + 1 && !engine.parallelDecks && after.stuck == 0 && blocks > 20 && moved > 0.25
            log(String(format: "Decks parallel Watchdog: Worker B hängt 150 ms -> Fristabläufe +%d, seriell %@, Hängedauer %.0f ms, %d Blöcke in 400 ms, A lief %.2f s · %@",
                       after.timeouts - wd.timeouts, "\(!engine.parallelDecks)", after.lastHang * 1000, blocks, moved, dogOK ? "OK" : "FAIL"))
            wd = engine.parallelWatchdog
        }
        engine.parallelDecks = was
        engine.bufferFrames = savedBuffer
        engine.apply(engine.routing, restart: true)
        if !wasPlaying { core.togglePlay(0) }
        log(String(format: "Decks parallel: Neustart der Ausgabe ×%d (Puffer 512/256/128, Ratenwechsel, Puffer am Gerät, Kern %.0f Hz): %d Schritte in %.1f s, Blöcke laufen %@, Fristabläufe %d · %@",
                   rounds, engine.sampleRate, steps, Date().timeIntervalSince(t), "\(ok)", wd.timeouts - t0 - (dogOK && ok ? 1 : 0), ok ? "OK" : "FAIL"))
        return ok && dogOK
    }

    /// MIX741_BENCH=memory: 4 lange Tracks (MIX741_BENCH_MIN Minuten, 10) laden, nur lokal vorhandene (nichts aus der
    /// Cloud), alle 4 spielen; Speicher (RSS, Footprint, fest), mlock-Fehler, Speicherdruck, Aussetzer beim Laden.
    /// Kernrate wie live mit MIX741_CORE_RATE (z. B. 96000)
    static func memoryProbe(_ core: MixController, tracks all: [Track]) async {
        let env = ProcessInfo.processInfo.environment
        let minSecs = (Double(env["MIX741_BENCH_MIN"] ?? "") ?? 10) * 60
        func local(_ t: Track) -> Bool {
            var st = stat()
            return stat(t.path, &st) == 0 && st.st_size > 0 && st.st_flags & UInt32(SF_DATALESS) == 0
        }
        let pick = Array(all.filter { $0.duration >= minSecs && $0.duration <= minSecs * 2.5 }
            .sorted { $0.duration > $1.duration }.lazy.filter(local).prefix(4))
        guard pick.count == 4 else { log("Speicherprobe: nur \(pick.count) lokale Tracks ≥ \(Int(minSecs / 60)) min"); return }
        func mem() -> String { Mem.line() }
        log(String(format: "Speicherprobe: Kern %.0f Hz, Gerät %.0f Hz · vorher %@", core.engine.sampleRate, core.engine.outputRate, mem()))
        for (d, t) in pick.enumerated() { log(String(format: "  %@: %.1f min · %@", deckLetters[d], t.duration / 60, t.title)) }
        core.engine.resetOverloads()
        _ = core.engine.takeLoad()
        let lock0 = core.fileService?.stats.lockFailures ?? 0, t0 = Date()
        for (d, t) in pick.enumerated() { core.load(t, deck: d) }
        for _ in 0..<1800 where (0..<4).contains(where: { core.trackAudio($0) == nil }) {
            let s = core.snapshot()
            if let e = (0..<4).compactMap({ s.decks[$0].error }).first { log("Speicherprobe: \(e)"); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let loaded = (0..<4).filter { core.trackAudio($0) != nil }.count
        let bytes = (0..<4).compactMap { core.trackAudio($0) }.reduce(0) { $0 + $1.frames * 2 * 4 }
        log(String(format: "Speicherprobe: %d/4 geladen in %.1f s, Audio %.2f GB (Float, Kernrate) · mlock fehlgeschlagen %d · %@",
                   loaded, Date().timeIntervalSince(t0), Double(bytes) / 1_073_741_824,
                   (core.fileService?.stats.lockFailures ?? 0) - lock0, mem()))
        for d in 0..<4 { core.updateDeck(d) { $0.keylock = true } }
        for d in 0..<4 where !core.snapshot().decks[d].playing { core.togglePlay(d) }
        try? await Task.sleep(for: .seconds(Double(env["MIX741_BENCH_SECS"] ?? "") ?? 10))
        let l = core.engine.takeLoad()
        log(String(format: "Speicherprobe: 4 Decks Keylock spielen · DSP %.1f %% · Spitze %.0f %% · über Budget %d · Gerät überlastet %d · %@",
                   l.average * 100, l.peak * 100, l.overloads, l.deviceOverloads, mem()))
        for d in 0..<4 where core.snapshot().decks[d].playing { core.togglePlay(d) }
    }

    /// MIX741_BENCH=load: Lastprobe am Gerät. 4 Decks mit Keylock (Tempo ±3 %), Hall auf FX 1 (A/C), Plugin auf FX 2
    /// (B/D, MIX741_BENCH_PLUGIN=<id>, Standard AUMatrixReverb, "none" = ohne), Delay auf FX 3 (alle 4 Decks).
    /// Puffer MIX741_BENCH_BUFFERS (512,256,128) je MIX741_BENCH_SECS s (8; live 600 = 30 min): DSP-Last (Mittel,
    /// Spitze), Blöcke über Budget (eigene Messung), Überlastmeldungen des Geräts, Zwischenstand jede Minute.
    /// Link-Nachführung ohne Netz: 10 s freie Clock (Clock-Master) gegen eine lokale Link-Zeitachse, angelegt am ersten
    /// Stempel; Policy wie im Steuertick, Clock hängt am Deck (nur Neusetzungen, keine Trims). Soll: 0 Neusetzungen.
    private static func linkDryRun(_ core: MixController) async {
        let e = core.engine
        guard let first = e.clockStamp else { log("Link trocken: kein Clock-Stempel"); return }
        let bps = core.clockTempo / 60, t0 = LinkSession.seconds(hostTicks: first.hostTime)
        var anchor = first.beat, policy = LinkLeadPolicy(), stats = LinkStats(), forces = 0, last: UInt64 = 0
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(5))
            guard let st = e.clockStamp, st.hostTime != last else { continue }
            last = st.hostTime
            let t = LinkSession.seconds(hostTicks: st.hostTime) - t0
            var diff = (st.beat - (anchor + bps * t)).truncatingRemainder(dividingBy: 4)
            if diff > 2 { diff -= 4 } else if diff < -2 { diff += 4 }
            stats.record(diff)
            if policy.step(diff: diff, canTrim: false) == .force { forces += 1; anchor = st.beat - bps * t }
        }
        let buf = Double(e.deviceBufferFrames) / max(1, e.outputRate) * 1000
        log(String(format: "Link trocken 10 s: %d Stempel · Phase max %.5f / σ %.5f Beats · Drift %+.5f · Neusetzungen %d (soll 0) · Stempel-Vorlauf %.2f ms (Puffer %.2f ms) · Präsentationslatenz %.2f ms",
                   stats.windowCount, stats.windowMax, stats.windowSigma, policy.drift, forces, e.renderLead * 1000, buf, e.presentationLatency * 1000))
        if core.snapshot().linkEnabled {
            let ls = core.linkStats()
            log(String(format: "Link echt: Neusetzungen %d · Clock-Trims %d · Tempo %d · Teilnehmer %d · Drift %+.4f",
                       ls.forces, ls.trims, ls.tempoSets, ls.peers, ls.drift))
        }
    }

    /// Stumm (Master 0); ohne MIX741_NOEXT auf dem externen Interface. Puffergröße wird danach zurückgestellt.
    /// Die Statusleiste holt dieselben Werte (4 Hz) ab: die Blockzahl zeigt, wie viel die Probe davon gesehen hat
    static func loadProbe(_ core: MixController, tracks c: [Track]) async {
        let engine = core.engine, env = ProcessInfo.processInfo.environment
        let secs = Double(env["MIX741_BENCH_SECS"] ?? "") ?? 8
        let buffers = (env["MIX741_BENCH_BUFFERS"] ?? "512,256,128").split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
        let plugin = env["MIX741_BENCH_PLUGIN"] ?? "aufx:mrev:appl"
        core.load(c[min(2, c.count - 1)], deck: 2)
        core.load(c[min(3, c.count - 1)], deck: 3)
        for _ in 0..<300 where core.trackAudio(2) == nil || core.trackAudio(3) == nil {
            let s = core.snapshot()
            if let e = s.decks[2].error ?? s.decks[3].error { log("Lastprobe: \(e)"); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard core.trackAudio(2) != nil, core.trackAudio(3) != nil else { log("Lastprobe: Decks C/D nicht geladen"); return }
        for d in 0..<4 { core.updateDeck(d) { $0.keylock = true; $0.tempoPct = d % 2 == 0 ? 3 : -3 } }
        core.updateFX(0) { $0.slots = [FXSlot(id: "REVERB", on: true, params: ["size": 0.8, "hp": 0.3, "lp": 1.0, "send": 1])]; $0.dryWet = 1 }
        if plugin != "none" {
            core.setSlots(1, [FXSlot(id: plugin)])
            for _ in 0..<200 where core.pluginParamNames(1).isEmpty && core.snapshot().pluginErrors[1] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let e = core.snapshot().pluginErrors[1] { log("Lastprobe: Plugin \(plugin): \(e)") }
            core.updateFX(1) { $0.slots[0].on = true; $0.dryWet = 0.5 }
        }
        let delayAssigned = (0..<4).map { core.snapshot().decks[$0].fxAssign[2] }
        for d in 0..<4 where !delayAssigned[d] { core.toggleFXAssign(d, 2) }
        core.updateFX(2) { $0.slots = [FXSlot(id: "DELAY", on: true, params: ["filter": 0.5, "feedback": 0.6, "rate": 0.5])]; $0.dryWet = 0.5 }
        for d in 0..<4 where !core.snapshot().decks[d].playing { core.togglePlay(d) }
        let saved = engine.bufferFrames
        log(String(format: "Lastprobe: Puffer %@ je %.0f s · Hall FX1 · Plugin FX2 %@ · Delay FX3 (A–D) · Keylock A–D",
                   buffers.map(String.init).joined(separator: "/"), secs, plugin))
        for frames in buffers {
            engine.bufferFrames = frames
            engine.apply(engine.routing, restart: true)
            try? await Task.sleep(for: .seconds(1))   // einschwingen, erste Blöcke nach dem Start nicht zählen
            engine.resetOverloads()
            _ = engine.takeLoad()
            var busy = 0.0, blocks = 0, peak = 0.0, minute = 0
            let t0 = Date()
            while Date().timeIntervalSince(t0) < secs {
                try? await Task.sleep(for: .milliseconds(50))
                let l = engine.takeLoad()
                busy += l.average * Double(l.blocks); blocks += l.blocks; peak = max(peak, l.peak)
                let m = Int(Date().timeIntervalSince(t0) / 60)
                if m > minute {
                    minute = m
                    log(String(format: "  Puffer %d · %d min: DSP %.1f %% · Spitze %.0f %% · über Budget %d · Gerät überlastet %d · Gerät neu verbunden %d",
                               frames, m, busy / Double(max(1, blocks)) * 100, peak * 100, l.overloads, l.deviceOverloads, l.reconnects))
                }
            }
            let l = engine.takeLoad()
            let playing = (0..<4).filter { core.snapshot().decks[$0].playing }.count
            log(String(format: "Lastprobe Puffer %d (Gerät %d Frames, %.1f ms Latenz, %.0f Hz, Kern %.0f Hz, %d Decks): DSP %.1f %% · Spitze %.0f %% · %d Blöcke in %.0f s · über Budget %d · Gerät überlastet %d",
                       frames, l.bufferFrames, l.outputLatency * 1000, l.sampleRate, engine.sampleRate, playing,
                       busy / Double(max(1, blocks)) * 100, peak * 100, blocks, secs, l.overloads, l.deviceOverloads))
        }
        engine.bufferFrames = saved
        engine.apply(engine.routing, restart: true)
        for d in 0..<4 where core.snapshot().decks[d].playing { core.togglePlay(d) }
        core.updateFX(2) { $0.slots[0].on = false }
        for d in 0..<4 where !delayAssigned[d] { core.toggleFXAssign(d, 2) }
        core.setSlots(1, [])
        core.updateFX(0) { $0.slots[0].on = false }
    }

    /// Vorhören im Kern, stumm (nur Pegel): Paar wie im Extern-Modus automatisch nach den Deck-Paaren des Testgeräts
    /// (2-Kanal-Gerät: keins frei -> 1/2), Ladezeit (zufälliger Track: meist dekodiert, dann aus dem Cache), Pegel, Sprung, Stopp.
    /// Deck A läuft weiter: Pegel und DSP-Last mit und ohne Vorhören
    static func previewProbe(_ mix: MixModel, tracks c: [Track]) async {
        let pv = mix.previewer, engine = mix.engine
        let r = engine.routing.firstChannel
        let pair = PreviewPlayer.autoPair(external: true, deckPairs: r, mainPair: 0, channels: engine.deviceChannels)
        pv.setOutput(firstChannel: pair ?? 0, mute: true)
        log("Vorhören: 12 Kanäle extern, Decks A 1/2 · B 5/6 · C 3/4 · D 7/8 -> automatisch "
            + (PreviewPlayer.autoPair(external: true, deckPairs: [0, 4, 2, 6], mainPair: 0, channels: 12).map { "\($0 + 1)/\($0 + 2)" } ?? "keins")
            + " · Testgerät \(engine.deviceChannels) Kanäle, Decks \(r.map { "\($0 + 1)/\($0 + 2)" }.joined(separator: " ")) -> "
            + (pair.map { "\($0 + 1)/\($0 + 2)" } ?? "keins frei, gemessen auf 1/2"))
        func measure() async -> (deck: Float, dsp: Double) {
            _ = engine.takeLoad()
            var acc: Float = 0
            for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(50)); acc += engine.levels[0].rms }
            return (acc / 20, engine.takeLoad().average)
        }
        let before = await measure()
        let t = c.count > 4 ? c[Int.random(in: 4..<c.count)] : c[c.count - 1]   // zufällig: meist noch nicht im Cache
        for round in 0..<2 {   // 1. dekodieren (oder Cache), 2. aus dem Cache
            mix.preview(t)
            for _ in 0..<3000 where mix.previewing == nil && mix.previewLoading != nil { try? await Task.sleep(for: .milliseconds(20)) }   // Cloud-Datei: bis 60 s
            guard mix.previewing != nil, let secs = mix.previewLoadSeconds else { log("Vorhören: nicht geladen"); return }
            log(String(format: "Vorhören Ladezeit %d: %.2f s (%@, %.0f s)", round + 1, secs, t.title, t.duration))
        }
        let p0 = pv.position
        let during = await measure()
        let lv = pv.level, routed = pv.routedPair
        log(String(format: "Vorhören: Pegel RMS %.3f · Spitze %.3f (stumm) · Paar %@ · lief %.2f s · Deck A RMS ohne/mit %.3f / %.3f · DSP ohne/mit %.1f / %.1f %%",
                   lv.rms, lv.peak, routed.map { "\($0 + 1)/\($0 + 2)" } ?? "keins", pv.position - p0, before.deck, during.deck,
                   before.dsp * 100, during.dsp * 100))
        if let v = mix.previewing {
            mix.seekPreview(v.key, fraction: 0.5)
            try? await Task.sleep(for: .milliseconds(200))
            log(String(format: "Vorhören Sprung auf 50 %%: Position %.2f s (Schnitt %.2f–%.2f)", pv.position, v.cut.lo, v.cut.hi))
        }
        mix.stopPreview()
        try? await Task.sleep(for: .milliseconds(300))
        log(String(format: "Vorhören gestoppt: spielt %@ · Pegel %.4f", "\(pv.playing)", pv.level.peak))
    }

    /// Schneiden, stumm, in einen temporären Ordner (nie neben die Originale, nichts in cuts.json): auf Deck A 64 Beats
    /// ab ~1:00 entfernen, während A spielt. Dauer, Quelle (Deck-Puffer / neu dekodiert), Länge und Rate der Datei,
    /// verschobenes Grid, längste Lücke des Hauptthreads (Takt 240 Hz). Die Datei wird danach gelöscht
    static func cutProbe(_ mix: MixModel, tracks c: [Track]) async {
        // 6-Minuten-Track (5:30–7:00) auf Deck C, sonst Deck A selbst
        var d = 0
        if let long = c.first(where: { $0.duration >= 330 && $0.duration <= 420 }) {
            mix.core.load(long, deck: 2)
            for _ in 0..<1500 where mix.core.trackAudio(2) == nil && mix.core.snapshot().decks[2].error == nil {
                try? await Task.sleep(for: .milliseconds(40))
            }
            if mix.core.trackAudio(2) != nil { d = 2 }
        }
        mix.pull()
        let s = mix.deck(d)
        guard s.track != nil, let g = s.grid, g.bpm > 0, s.duration > 120 else { log("Schneiden: übersprungen (Deck ohne Grid)"); return }
        let a = g.time(ofBeat: g.beatPosition(at: 60).rounded())
        let r = TrackRange(a, a + 64 * g.beat)
        mix.setRange(d, r)
        final class Gap: @unchecked Sendable { var worst = 0.0, last = CACurrentMediaTime(), hits: [(Double, Double)] = [] }
        let gap = Gap()
        let tick = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let now = CACurrentMediaTime()
            gap.worst = max(gap.worst, now - gap.last)
            if now - gap.last > 0.016 { gap.hits.append((now, now - gap.last)) }
            gap.last = now
        }
        RunLoop.main.add(tick, forMode: .common)
        try? await Task.sleep(for: .seconds(1))
        let idle = gap.worst
        gap.worst = 0
        gap.hits = []
        CutJob.lastResult = nil
        let t0 = Date(), c0 = CACurrentMediaTime()
        mix.cutRange(d, mode: .remove, load: false)
        while CutJob.running, Date().timeIntervalSince(t0) < 120 { try? await Task.sleep(for: .milliseconds(20)) }
        let c1 = CACurrentMediaTime()
        try? await Task.sleep(for: .milliseconds(500))
        tick.invalidate()
        log("Schneiden: Lücken > 16 ms (s ab Start, ms): " + gap.hits.map { String(format: "%.2f/%.0f", $0.0 - c0, $0.1 * 1000) }.joined(separator: " ")
            + String(format: " · fertig bei %.2f s", c1 - c0))
        mix.setRange(d, nil)
        guard let res = CutJob.lastResult else { log("Schneiden: kein Ergebnis"); return }
        let url = URL(fileURLWithPath: res.track.path)
        let f = try? AVAudioFile(forReading: url)
        let secs = f.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let want = s.duration - r.length
        let ng = BeatGrid(track: res.track)
        log(String(format: "Schneiden Deck %@ (%.0f s, A spielt, Bereich %.1f–%.1f s entfernt): %.2f s (%@) · Datei %.3f s, soll %.3f · %.0f Hz · %d Kanäle · Apple Lossless %@ · Grid-Anker %.3f -> %.3f s · Hotcues %@ -> %@ · Hauptthread längste Lücke %.0f ms (1 s davor ohne Schneiden %.0f ms, Abschluss %.1f ms) · %@",
                   deckLetters[d], s.duration, r.start, r.end, res.seconds, res.fromDeck ? "Deck-Puffer" : "Datei neu dekodiert", secs, want, f?.processingFormat.sampleRate ?? 0,
                   Int(f?.processingFormat.channelCount ?? 0),
                   "\(f?.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)", g.anchor, ng?.anchor ?? .nan,
                   s.hotcues.values.map { String(format: "%.1f", $0.startMs / 1000) }.sorted().joined(separator: "/"),
                   res.track.hotcues.map { String(format: "%.1f", $0.startMs / 1000) }.joined(separator: "/"),
                   gap.worst * 1000, idle * 1000, CutJob.mainSeconds * 1000, abs(secs - want) < 0.01 ? "ok" : "LÄNGE FALSCH"))
        try? FileManager.default.removeItem(at: url)
    }

    /// Rückgängig: auf Deck B (spielt, Sync) Hotcue setzen, Beatjump, Loop, Schnitt OUT, Grid-Anker verschieben, dann alles
    /// zurück und vergleichen; Preparation und Metadaten (nur im Speicher). Kosten: Sicherung je Aktion (zwei Kopien)
    static func undoProbe(_ mix: MixModel, store: LibraryStore) async {
        let d = 1, u = UndoStack.shared
        mix.pull()
        let s = mix.deck(d)
        guard s.track != nil, let g = s.grid, g.bpm > 0, s.duration > 60,
              let n = (0..<8).first(where: { s.hotcues[$0] == nil }) else { log("Rückgängig: übersprungen"); return }
        let before = mix.core.deckEdit(d), steps = u.done.count
        var ms: [Double] = []
        func timed(_ f: () -> Void) { let t = CACurrentMediaTime(); f(); ms.append((CACurrentMediaTime() - t) * 1000) }
        timed { mix.hotcue(d, n) }
        let p0 = mix.position(d)
        timed { mix.beatjump(d, beats: 16) }
        let jumped = mix.position(d) - p0
        timed { mix.autoLoop(d, size: 4) }
        timed { mix.setTrimPoint(d, end: true, s.duration - 20) }
        timed { mix.shiftGridBeats(d, 1) }
        let recorded = u.done.count - steps, label = u.undoLabel ?? "–"
        let changed = mix.core.deckEdit(d)
        for _ in 0..<3 { u.undo() }   // Grid, Schnitt, Loop
        let p1 = mix.position(d)
        u.undo()   // Beatjump: Position um den Sprung zurück (B läuft weiter)
        let back = mix.position(d) - p1
        u.undo()   // Hotcue
        let after = mix.core.deckEdit(d)
        let ok = recorded == 5 && changed.hotcues[n] != nil && after.hotcues == before.hotcues && after.trim == before.trim
            && after.grid == before.grid && after.gridEdited == before.gridEdited && after.loopActive == before.loopActive
            && abs(back + jumped) < 0.05
        // Sicherung allein (Kopie des Bearbeitungsstands unter der Sperre)
        let t0 = CACurrentMediaTime()
        for _ in 0..<1000 { _ = mix.core.deckEdit(d) }
        let snap = (CACurrentMediaTime() - t0) * 1000   // ms für 1000 = µs je Kopie
        // Preparation und Metadaten
        let keys = store.tracks.prefix(2).map(\.key)
        let prep0 = store.preparation
        store.appendToPreparation(keys)
        let prepAdded = store.preparation.count - prep0.count
        u.undo()
        let prepOK = prepAdded == keys.count && store.preparation == prep0
        var metaOK = false
        if let k = keys.first, let c0 = store.track(k)?.comment {
            store.applyEdits([k: [.comment: c0 + " undo"]], writeBack: false)
            let set = store.track(k)?.comment == c0 + " undo"
            u.undo()
            metaOK = set && store.track(k)?.comment == c0
        }
        log(String(format: "Rückgängig Deck %@: %d Schritte (oben: %@), Beatjump %+.2f s -> zurück %+.2f s, Hotcues/Schnitt/Grid/Loop wie vorher %@ · Preparation %@ · Metadaten %@ · Aktion mit Sicherung %@ ms · Kopie %.1f µs",
                   deckLetters[d], recorded, label, jumped, back, ok ? "ok" : "FALSCH", prepOK ? "ok" : "FALSCH", metaOK ? "ok" : "FALSCH",
                   ms.map { String(format: "%.2f", $0) }.joined(separator: "/"), snap))
        if !(ok && prepOK && metaOK) { log("RÜCKGÄNGIG FALSCH"); exit(1) }
    }

    /// Aufnahme „Interner Master“ stumm in einen temporären Ordner: DSP-Last und Kosten des Abgriffs ohne / mit Aufnahme,
    /// Deck C startet während der Aufnahme -> Datei (Länge ±1 Block zur Laufzeit), .txt / .cue mit dem Track.
    /// Eingang ohne Gerät: sauberer Fehler, keine Aufnahme, kein Absturz. Ordner danach gelöscht
    static func recordProbe(_ mix: MixModel, tracks c: [Track]) async {
        func fail(_ s: String) -> Never { log("Aufnahme: \(s)"); log("AUFNAHME FALSCH"); exit(1) }
        let rec = mix.recorder, engine = mix.engine
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-selftest-rec-\(getpid())", isDirectory: true)
        let savedPrefs = mix.prefs.record
        defer {
            rec.folderOverride = nil; rec.testSource = nil
            mix.prefs.record = savedPrefs
            try? FileManager.default.removeItem(at: dir)
        }
        rec.folderOverride = dir
        // Last ohne Aufnahme (Decks A/B laufen wie im übrigen Test oder stehen)
        func load(_ secs: Double) async -> MixEngine.RenderLoad {
            _ = engine.takeLoad(); _ = engine.takeTapCost()
            try? await Task.sleep(for: .seconds(secs))
            return engine.takeLoad()
        }
        let t = c.count > 2 ? c[2] : c[0]
        mix.core.load(t, deck: 2)
        for _ in 0..<500 where mix.core.trackAudio(2) == nil && mix.core.snapshot().decks[2].error == nil { try? await Task.sleep(for: .milliseconds(40)) }
        guard mix.core.trackAudio(2) != nil else { fail("Deck C lädt nicht") }
        if !mix.deck(0).playing { mix.core.togglePlay(0) }
        let without = await load(2)
        rec.testSource = .master
        rec.start()
        for _ in 0..<200 where rec.preparing { try? await Task.sleep(for: .milliseconds(10)) }   // Ordner/Name im Hintergrund
        guard rec.recording, let url = rec.url, let started = rec.startedAt else { fail("startet nicht (\(StatusCenter.shared.current?.text ?? "-"))") }
        let with = await load(2)   // gleiche Decks wie ohne, nur der Abgriff dazu
        let cost = engine.takeTapCost()
        mix.core.togglePlay(2)
        // History meldet Deck C nach der Schwelle (Test: 3 s)
        for _ in 0..<100 where !(rec.history?.live.contains { $0.key == t.key && $0.start >= started } ?? false) { try? await Task.sleep(for: .milliseconds(100)) }
        let stopAt = Date()
        rec.stop()
        for _ in 0..<100 where rec.recording { try? await Task.sleep(for: .milliseconds(50)) }
        mix.core.togglePlay(2)
        guard !rec.recording, let stats = rec.lastStats else { fail("stoppt nicht") }
        let ran = stopAt.timeIntervalSince(started), secs = Double(stats.frames) / engine.sampleRate
        log(String(format: "Aufnahme Master: DSP ohne / mit %.1f / %.1f %% (Spitze %.1f / %.1f %%) · schwerster Block %.3f / %.3f ms (%d Frames) · Abgriff %.4f ms je Block (schwerster %.4f ms, %d Blöcke)",
                   without.average * 100, with.average * 100, without.peak * 100, with.peak * 100,
                   without.worstTotalMs, with.worstTotalMs, with.worstFrames,
                   cost.blocks > 0 ? cost.totalMs / Double(cost.blocks) : 0, cost.worstMs, cost.blocks))
        log(String(format: "Aufnahme Master: %@ · %.2f s in der Datei, %.2f s gelaufen · %d Aussetzer", url.lastPathComponent, secs, ran, stats.overflows))
        guard FileManager.default.fileExists(atPath: url.path), let f = try? AVAudioFile(forReading: url) else { fail("Datei fehlt") }
        guard Int(f.length) == stats.frames, abs(secs - ran) <= 1.0, f.fileFormat.sampleRate == engine.sampleRate else {
            fail(String(format: "Länge %lld Frames (%.2f s) zu %.2f s gelaufen, Rate %.0f", f.length, secs, ran, f.fileFormat.sampleRate))
        }
        guard stats.overflows == 0 else { fail("\(stats.overflows) Aussetzer") }
        let stem = url.deletingPathExtension()
        let txt = (try? String(contentsOf: stem.appendingPathExtension("txt"), encoding: .utf8)) ?? ""
        let cue = (try? String(contentsOf: stem.appendingPathExtension("cue"), encoding: .utf8)) ?? ""
        for _ in 0..<20 where txt.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        let txt2 = txt.isEmpty ? ((try? String(contentsOf: stem.appendingPathExtension("txt"), encoding: .utf8)) ?? "") : txt
        let cue2 = cue.isEmpty ? ((try? String(contentsOf: stem.appendingPathExtension("cue"), encoding: .utf8)) ?? "") : cue
        guard txt2.contains(t.title), cue2.contains("INDEX 01") else { fail("Tracklist ohne \(t.title): \(txt2.debugDescription)") }
        log("Aufnahme Tracklist: " + txt2.split(separator: "\n").joined(separator: " | "))
        // Eingang ohne Gerät: Fehler in der Statuszeile, keine Aufnahme
        rec.testSource = .input
        mix.prefs.record.inputUID = "minos741-selftest-no-such-device"
        rec.start()
        for _ in 0..<200 where rec.preparing { try? await Task.sleep(for: .milliseconds(10)) }
        guard !rec.recording else { fail("Eingang ohne Gerät nimmt auf") }
        log("Aufnahme Eingang ohne Gerät: \(StatusCenter.shared.current?.text ?? "-") · läuft \(rec.recording)")
        log("AUFNAHME OK")
    }

    /// wird vom HistoryStore gesetzt, damit der Test genau seine eigene Datei entfernen kann
    nonisolated(unsafe) static var historyURL: URL?

    /// Auto-Loop beim Laden (16 Takte): nur ohne gespeicherten Loop, Lage wie berechnet, nicht aktiv; Reloop springt hinein
    static func autoLoopCheck(_ core: MixController) {
        var reloops = 0
        for d in 0..<2 {
            let s = core.snapshot().decks[d], l = core.engine.loop(d)
            let isLoop = { (c: Cue) in c.kind == .loop && c.lengthMs > 0 }
            let stored = s.hotcues.values.contains(where: isLoop) || (s.track?.cues.contains { $0.hotcue < 0 && isLoop($0) } ?? false)
            let want = stored ? nil : MixController.autoLoopRange(grid: s.grid, phraseAnchor: s.phraseTarget, bars: 16, range: s.playRange)
            let ok = s.autoLoop == (want != nil) && !l.active
                && want.map { abs($0.start - l.start) < 1e-6 && abs($0.end - l.end) < 1e-6 } ?? true
            guard ok else {
                log(String(format: "AUTO-LOOP FALSCH %@: auto %@ aktiv %@ · %.3f–%.3f s, soll %@", deckLetters[d], "\(s.autoLoop)", "\(l.active)",
                           l.start, l.end, want.map { String(format: "%.3f–%.3f s", $0.start, $0.end) } ?? "keiner"))
                exit(1)
            }
            guard want != nil, let g = s.grid else { log("Auto-Loop \(deckLetters[d]): keiner (\(stored ? "Track hat einen Loop" : "kein Grid / kein Platz"))"); continue }
            core.reloop(d)
            let r = core.engine.loop(d), pos = core.position(d)
            guard r.active, core.snapshot().decks[d].loopActive, !core.snapshot().decks[d].autoLoop,
                  abs(r.end - r.start - 64 * g.beat) < 1e-6, abs(pos - r.start) < 0.01 else {
                log(String(format: "AUTO-LOOP FALSCH %@: Reloop aktiv %@ · %.3f–%.3f s, Position %.3f", deckLetters[d], "\(r.active)", r.start, r.end, pos))
                exit(1)
            }
            core.exitLoop(d)
            core.seek(d, seconds: s.cuePoint)
            reloops += 1
            log(String(format: "Auto-Loop %@: %.3f–%.3f s (16 Takte), nicht aktiv; Reloop -> aktiv, Position am Anfang", deckLetters[d], r.start, r.end))
        }
        log("AUTO-LOOP OK (\(reloops) Decks mit Auto-Loop)")
    }

    /// Controller-Startsequenz ohne Gerät: Generator über die volle Dauer im LED-Takt, Reports mit normalem Zustand
    static func ledShowProbe() {
        var normal = [UInt8](repeating: 0, count: 0x34), normalDisp = [UInt8](repeating: 0, count: LEDShow.displayLength)
        normal[0] = 0x80; normalDisp[0] = 0x81
        var frames = 0, phases = Set<Int>()
        let t0 = CACurrentMediaTime()
        var t = 0.0
        while let f = LEDShow.frame(at: t, decks: (0, 2), seed: 741) {
            _ = LEDShow.reports(f, peak: 127, normal: (normal, normalDisp))
            frames += 1
            phases.insert(f.phase.rawValue)
            t += LEDShow.step
        }
        let ms = (CACurrentMediaTime() - t0) * 1000 / Double(max(1, frames))
        let ok = abs(frames - Int((LEDShow.duration / LEDShow.step).rounded(.up))) <= 1 && phases.count == 3 && ms < 0.1
        log(String(format: "Startsequenz: %d Frames über %.2f s, %.3f ms je Frame (Generator + Reports) · %@",
                   frames, LEDShow.duration, ms, ok ? "OK" : "FAIL"))
        if !ok { log("STARTSEQUENZ FALSCH"); exit(1) }
    }

    /// Suche in den Einstellungen: Indexgröße, Zeit für 3 Zeichen (Mittel aus 50 Läufen), Treffer für „puffer“
    static func settingsSearchProbe() {
        let s = SettingsSearch.shared
        _ = s.search("loo")
        let t0 = CACurrentMediaTime()
        for _ in 0..<10 { for q in ["loo", "puf", "rev", "bpm", "cue"] { _ = s.search(q) } }
        let ms = (CACurrentMediaTime() - t0) * 1000 / 50
        let first = s.search("puffer").first?.entry.anchor ?? "-"
        let ok = ms < 2 && first == "audio.buffer"
        log(String(format: "Einstellungs-Suche: %d Einträge (%d Anker), %.3f ms je Suche (3 Zeichen), puffer -> %@ · %@",
                   s.entries.count, Set(s.entries.map(\.anchor)).count, ms, first, ok ? "OK" : "FAIL"))
        if !ok { log("EINSTELLUNGS-SUCHE FALSCH"); exit(1) }
    }

    static func log(_ s: String) {
        print("[selftest] \(s)")
        fflush(stdout)
    }
}

/// Speicher des Prozesses und des Systems (Messungen)
@MainActor enum Mem {
    static func rss() -> UInt64 {
        var info = mach_task_basic_info()
        var n = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) } }
        return r == KERN_SUCCESS ? info.resident_size : 0
    }

    /// fest (wired) im ganzen System
    static func wired() -> UInt64 {
        var vm = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }
        return r == KERN_SUCCESS ? UInt64(vm.wire_count) * UInt64(vm_kernel_page_size) : 0
    }

    /// Speicherdruck des Systems: normal · warnung · kritisch
    static func pressure() -> String {
        var level: Int32 = 0, size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return [1: "normal", 2: "warnung", 4: "kritisch"][Int(level)] ?? "\(level)"
    }

    static func gb(_ b: UInt64) -> String { String(format: "%.2f GB", Double(b) / 1_073_741_824) }

    static func line() -> String {
        "RSS \(gb(rss())) · Footprint \(gb(MeterSampler.footprint())) · System fest \(gb(wired())) · Speicherdruck \(pressure())"
    }
}

/// Nur Bild (MIX741_SHOT=wave:<png>, Selbsttest): die Wellenform-Ebene eines Decks offscreen rendern – kein Fenster,
/// kein Audio, keine Controller. Oben der Zoom aus den Einstellungen, unten 4× weiter heraus; Grid-Anker links im Bild,
/// Spielkopf in einem 4-Beat-Loop, zwei Hotcues, darunter die Übersicht. Erster Track der Collection mit 120–140 BPM und Grid, wie im Selbsttest.
/// Optional: MIX741_SHOT_TRACK (Teil von Interpret/Titel/Pfad), MIX741_SHOT_AT (Sekunden, Spielkopf, ohne Loop),
/// MIX741_SHOT_SPAN (Sekunden je Seite), MIX741_SHOT_STYLE (Komma-Liste: blend, 3band, spectrum, fine, fine-mix, mono →
/// je Stil zwei Streifen untereinander, beschriftet), MIX741_SHOT_PALETTE (rgb, bone, orange, blue, classic), MIX741_SHOT_BOOST.
@MainActor
enum WaveShot {
    static func run(path: String) -> Never {
        do {
            try render(to: URL(fileURLWithPath: path))
            SelfTest.log("SHOT \(path)")
            exit(0)
        } catch {
            SelfTest.log("SHOT Fehler: \(error)")
            exit(1)
        }
    }

    enum ShotError: Error { case noTrack, context, png }

    /// Stil-Kürzel → (Stil, Beschriftung)
    private static func look(_ k: String, _ ui: UIPrefs) -> (WaveformStyle, String) {
        switch k.trimmingCharacters(in: .whitespaces) {
        case "blend": (.blend, "3-band blend")
        case "spectrum", "fine": (.spectrum, "spectrum (6 bands)")
        case "mono": (.mono, "mono")
        default: (ui.waveformStyle, "settings")
        }
    }

    private static func render(to url: URL) throws {
        let env = ProcessInfo.processInfo.environment
        var ui = AppPrefs.load().ui
        if let p = env["MIX741_SHOT_PALETTE"] {
            ui.waveformPalette = ["rgb": .rgb, "bone": .bone, "orange": .orange, "blue": .blue, "classic": .classic][p] ?? ui.waveformPalette
        }
        if let b = env["MIX741_SHOT_BOOST"].flatMap(Double.init) { ui.waveformHighBoost = b }
        if let sp = env["MIX741_SHOT_SPAN"].flatMap(Double.init) { ui.waveformSeconds = sp }
        let tracks = try NMLParser.parse(url: LibraryStore.defaultNML).tracks
        let want = env["MIX741_SHOT_TRACK"]?.lowercased()
        guard let t = tracks.first(where: { t in
            guard FileManager.default.fileExists(atPath: t.path) else { return false }
            if let want { return "\(t.artist) \(t.title) \(t.path)".lowercased().contains(want) }
            return t.bpm > 120 && t.bpm < 140 && t.gridAnchorMs != nil
        }) else { throw ShotError.noTrack }
        let grid = BeatGrid(track: t)
        SelfTest.log("Track: \(t.artist) – \(t.title) \(t.bpm) BPM")
        let file = URL(fileURLWithPath: t.path)
        let rate = try AVAudioFile(forReading: file).processingFormat.sampleRate   // Dateirate: keine Wandlung nötig
        let t0 = Date()
        let audio = try TrackAudio.decode(url: file, sampleRate: rate)
        SelfTest.log(String(format: "dekodiert + analysiert: %.2f s für %.0f s Audio", Date().timeIntervalSince(t0), audio.duration))
        let at = env["MIX741_SHOT_AT"].flatMap(Double.init)
        let pos = at ?? grid.map { $0.time(ofBeat: 6.3) } ?? 10
        let loop = at == nil && grid != nil
            ? (active: true, start: grid!.time(ofBeat: 4), end: grid!.time(ofBeat: 8)) : (active: false, start: 0.0, end: 0.0)
        var looks = (env["MIX741_SHOT_STYLE"] ?? "settings").split(separator: ",").map { look(String($0), ui) }
        // Versuchswerte der Mischung je Zeile: MIX741_SHOT_TUNE="sat,win,gl,gm,gh,base,fade,stack,warm,open;…" (eine Zeile je Eintrag,
        // Stil der ersten Zeile); MIX741_SHOT_PRESET=all|0,3,blend.f,<Name>: eingebaute Presets (Index, ID) oder eigene
        // (Name), eine Zeile je Preset; ohne: Preset der Einstellungen (MIX741_SHOT_PALETTE / _BOOST: wie früher Farben + Variante)
        let tunes = (env["MIX741_SHOT_TUNE"] ?? "").split(separator: ";").compactMap { BlendPaint.Tune(String($0)) }
        if !tunes.isEmpty, let first = looks.first { looks = tunes.map { (first.0, first.1 + " · " + $0.label) } }
        let list = WavePresetList(builtIn: WavePresets.builtIn, custom: (try? Data(contentsOf: HistoryStore.baseDir.appendingPathComponent("wave-presets.json")))
            .flatMap { try? WavePresetList.decodeCustom($0) } ?? [])
        let legacy = WavePresets.migrate(palette: ui.waveformPalette, highBoost: ui.waveformHighBoost, variant: ui.blendPreset)
        var presets: [WavePreset] = [env["MIX741_SHOT_PALETTE"] != nil || env["MIX741_SHOT_BOOST"] != nil || ui.wavePreset.isEmpty
                                     ? legacy.created ?? list.resolved(legacy.id) : list.resolved(ui.wavePreset)]
        if let ps = env["MIX741_SHOT_PRESET"] {
            presets = ps == "all" ? list.builtIn : ps.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.compactMap { k in
                Int(k).map { list.builtIn[max(0, min(list.builtIn.count - 1, $0))] } ?? list.all.first { $0.id == k || $0.name == k }
            }
            looks = presets.map { (WaveformStyle.blend, $0.name) }
        }
        let w: CGFloat = 1200, h: CGFloat = 180, gap: CGFloat = 8, label: CGFloat = 18, scale: CGFloat = 2, oh: CGFloat = 48
        let rowH = (label + h * 2 + oh + gap * 3)
        let totalH = rowH * CGFloat(looks.count)
        guard let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(totalH * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ShotError.context }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor(Theme.background).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: totalH))
        let tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in }   // hält den Run-Loop wach
        defer { tick.invalidate() }
        for (row, lk) in looks.enumerated() {
            WaveLayerNSView.tileTime.withLock { $0 = (0, 0) }
            let tr = Date()
            let preset = presets.count > 1 ? presets[row] : presets[0]
            let blend = preset.analysis == .standard ? nil
                : BlendAnalyzer.analyze(left: audio.left, right: audio.right, frames: audio.frames, sampleRate: audio.sampleRate, blocks: audio.peak.count, params: preset.analysis)
            let wf = RenderedWaveform.render(audio, style: lk.0, palette: ui.waveformPalette, highBoost: ui.waveformHighBoost,
                                             preset: preset, blend: blend, tune: tunes.isEmpty ? nil : tunes[row])
            SelfTest.log(String(format: "%@: Wellenform gerechnet in %.2f s, %.0f Pfade je Abschnitt", lk.1, Date().timeIntervalSince(tr), Double(wf.chunks.reduce(0) { $0 + $1.layers.count }) / Double(max(1, wf.chunks.count))))
            let view = WaveLayerNSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            view.position = { pos }
            view.loop = { loop }
            view.wave = wf
            var scene = WaveScene(
                waveID: ObjectIdentifier(wf), duration: audio.duration, grid: grid, span: ui.waveformSeconds,
                showGrid: true, colorful: ui.colorfulGrid, phraseBeats: ui.phraseBeats, barNumbers: ui.showBarNumbers, barMarkers: ui.barMarkers,
                boldLines: ui.gridLineWeight == .bold,
                dimPlayed: ui.dimPlayed,
                cues: grid.map { g in [WaveScene.Mark(t: g.time(ofBeat: 2), number: 1, color: NSColor(Theme.cueColor(.cue))),
                                       WaveScene.Mark(t: g.time(ofBeat: 12), number: 2, color: NSColor(Theme.cueColor(.loop)))] } ?? [],
                cuePoint: grid?.anchor ?? 0, hasTrack: true)
            let top = totalH - CGFloat(row) * rowH   // CG: y nach oben
            let text = String(format: "%@ · %@ – %@ · %.0f s", lk.1, t.artist, t.title, pos) as NSString
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: NSPoint(x: 6, y: top - label + 3),
                      withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(Theme.bone)])
            NSGraphicsContext.restoreGraphicsState()
            for (i, span) in [ui.waveformSeconds, ui.waveformSeconds * 4].enumerated() {
                scene.span = span
                view.scene = scene
                RunLoop.main.run(until: Date() + 1.5)   // Kacheln kommen von der Hintergrund-Queue auf den Hauptthread
                ctx.saveGState()
                ctx.translateBy(x: 0, y: top - label - h - CGFloat(i) * (h + gap))
                view.layer?.render(in: ctx)
                ctx.restoreGState()
            }
            let tt = WaveLayerNSView.tileTime.withLock { $0 }
            SelfTest.log(String(format: "%@: %d Kacheln, %.2f ms je Kachel", lk.1, tt.count, tt.seconds * 1000 / Double(max(1, tt.count))))
            // Übersicht (ganzer Track) darunter
            if let img = wf.overview {
                let r = CGRect(x: 0, y: top - label - h * 2 - gap * 2 - oh, width: w, height: oh)
                ctx.setFillColor(NSColor(Theme.wave).cgColor)
                ctx.fill(r)
                ctx.draw(img, in: r)
            }
        }
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ShotError.png }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw ShotError.png }
    }
}

extension SelfTest {
    /// EDIT-Modus auf Deck A (spielt): 16 Beats entfernen, Marke, Segment duplizieren -> das Deck spielt die gerenderte
    /// Liste (Längen frame-genau), Tool-Loop 8 aus der Vorschau in den Test-Ordner (Länge = beats · 60 / bpm · rate),
    /// alles zurück per Rückgängig, EDIT wie vorher. Nichts in edits.json, nichts neben Christians Dateien
    static func editProbe(_ mix: MixModel) async {
        let d = 0
        mix.pull()
        let s0 = mix.deck(d)
        guard s0.track != nil, let g = s0.grid, g.bpm > 0, s0.duration > 120 else { log("EDIT: übersprungen (Deck ohne Grid)"); return }
        let wasEditing = mix.editing(d), u = UndoStack.shared
        func settle() async {
            for _ in 0..<500 where mix.editSession(d)?.rendering == true { try? await Task.sleep(for: .milliseconds(20)) }
            mix.pull()
        }
        mix.setEditing(d, true)
        await settle()
        guard let session = mix.editSession(d) else { log("EDIT FALSCH: keine Sitzung"); exit(1) }
        if !session.shown.isPlain || session.shown.segments.count > 1 { mix.editReset(d); await settle() }
        let n0 = u.done.count
        let src = session.source, rate = src.sampleRate
        let dur0 = mix.deck(d).duration
        let a = g.time(ofBeat: (g.beatPosition(at: 40) / 4).rounded() * 4), len = 16 * g.beat
        mix.setRange(d, TrackRange(a, a + len))
        let t0 = CACurrentMediaTime()
        mix.editAction(d, .remove)
        let main = CACurrentMediaTime() - t0
        await settle()
        let removed = mix.deck(d).duration, preview1 = mix.core.trackAudio(d) === session.preview && session.preview != nil
        let want1 = Double(src.frames - (Int(((a + len) * rate).rounded()) - Int((a * rate).rounded()))) / rate
        let render1 = EditRender.lastSeconds, swap1 = EditRender.lastSwapSeconds
        // Marke 8 Beats hinter der Naht, das Stück davor (Naht -> Marke) duplizieren
        mix.editMark(d, at: a + 8 * g.beat)
        let segs = mix.editSession(d)?.shown.segments.count ?? 0
        mix.setRange(d, TrackRange(a, a + 8 * g.beat))
        mix.editAction(d, .duplicate)
        await settle()
        let dup = mix.deck(d).duration
        let want2 = want1 + Double(Int(((a + len + 8 * g.beat) * rate).rounded()) - Int(((a + len) * rate).rounded())) / rate
        // Tool-Loop aus der Vorschau: an der Naht, ohne Schleife aus früheren Schritten (Lage hing sonst am Lauf davor)
        CutJob.lastResult = nil
        mix.core.exitLoop(d)
        mix.core.seek(d, seconds: a)
        mix.pull()
        mix.exportToolLoop(d, beats: 8)
        let tl0 = Date()
        while CutJob.running, Date().timeIntervalSince(tl0) < 30 { try? await Task.sleep(for: .milliseconds(20)) }
        var loopOK = false, loopText = "-"
        if let r = CutJob.lastResult {
            let url = URL(fileURLWithPath: r.track.path)
            if let f = try? AVAudioFile(forReading: url) {
                let want = ToolLoop.frames(beats: 8, bpm: g.bpm, rate: f.processingFormat.sampleRate)
                loopOK = Int(f.length) == want && r.track.title.hasSuffix("[tool-loop 8]") && ToolLoop.isToolLoop(r.track, separators: mix.prefs.ui.tagSeparators)
                loopText = String(format: "%@ · %lld / %d Frames · %.2f s", url.lastPathComponent, f.length, want, r.seconds)
            }
            try? FileManager.default.removeItem(at: url)
        }
        // alles zurück
        while u.done.count > n0 { u.undo() }
        await settle()
        let back = mix.deck(d).duration, original = mix.core.trackAudio(d) === src
        mix.setRange(d, nil)
        mix.setEditing(d, wasEditing)
        mix.pull()
        let ok = preview1 && abs(removed - want1) < 1.5 / rate && segs >= 3 && abs(dup - want2) < 1.5 / rate && loopOK
            && original && abs(back - dur0) < 1e-6
        log(String(format: "EDIT Deck %@ (spielt %@): 16 Beats entfernt %.3f -> %.3f s (soll %.3f), Rendern %.0f ms (Hintergrund), Tausch %.1f ms, Aktion %.2f ms (Hauptthread) · Marke -> %d Stücke · DUP %.3f s (soll %.3f) · Tool-Loop %@ · Rückgängig -> Original %@ %.3f s · %@",
                   deckLetters[d], "\(s0.playing)", dur0, removed, want1, render1 * 1000, swap1 * 1000, main * 1000, segs, dup, want2, loopText,
                   "\(original)", back, ok ? "ok" : "FALSCH"))
        if !ok { log("EDIT FALSCH"); exit(1) }
    }

    /// Groove → MIDI an Deck A: Muster lesen, alle Stile erzeugen (keine Doppelung der Track-Hats), .mid rundreise,
    /// MIDI-Quelle (versteckt) 2 s im Takt der Clock, eigener Eingang misst Zeitstempel gegen das 16tel-Raster der Clock
    static func grooveProbe(_ mix: MixModel) async {
        let g = GrooveCenter.shared, core = mix.core
        guard core.trackAudio(0) != nil, mix.deck(0).grid != nil else { log("Groove: Deck A ohne Track – übersprungen"); return }
        let wasPlaying = mix.deck(0).playing
        if !wasPlaying { core.togglePlay(0); try? await Task.sleep(for: .milliseconds(300)) }
        mix.pull()
        let t0 = CACurrentMediaTime()
        guard g.analyze(mix, 0), let p = g.slots[0].pattern else { log("Groove FEHLER: kein Muster"); exit(1) }
        let ms = (CACurrentMediaTime() - t0) * 1000
        // MIX741_GROOVE_DEBUG=<Beat,Beat…>: Messwerte je Schritt (Anstieg / Spitze je Gruppe, Höhen-Dauer)
        if let dbg = ProcessInfo.processInfo.environment["MIX741_GROOVE_DEBUG"], let a = core.trackAudio(0), let grid = mix.deck(0).grid {
            let bps = a.sampleRate / Double(TrackAudio.blockFrames(sampleRate: a.sampleRate))
            if dbg == "all" {
                for d in 0..<2 {
                    guard let a = core.trackAudio(d), let grid = mix.deck(d).grid else { continue }
                    let bps = a.sampleRate / Double(TrackAudio.blockFrames(sampleRate: a.sampleRate))
                    log("Groove debug \(deckLetters[d]): \(mix.deck(d).track?.title ?? "-")")
                    for b in stride(from: 0.0, to: grid.beatPosition(at: a.duration) - 8, by: 32) {
                        let pat = GrooveAnalyzer.extract(a.spectrum, blocksPerSecond: bps, grid: grid, startBeat: b, beats: 8)
                        log("  \(Int(b)): K \(pat.steps(.kick)) S \(pat.steps(.snare)) H \(pat.steps(.closedHat)) O \(pat.steps(.openHat))")
                    }
                }
            }
            for b in dbg.split(separator: ",").compactMap({ Double($0) }) {
                let pat = GrooveAnalyzer.extract(a.spectrum, blocksPerSecond: bps, grid: grid, startBeat: b, beats: 8)
                log("Groove debug Beat \(Int(b)): Kick \(pat.steps(.kick)) Snare \(pat.steps(.snare)) Hats \(pat.steps(.closedHat)) offen \(pat.steps(.openHat))")
                for (i, m) in GrooveAnalyzer.measure(a.spectrum, blocksPerSecond: bps, grid: grid, startBeat: b, steps: 32).enumerated() {
                    log(String(format: "  %2d  K %5.1f/%6.1f  M %5.1f/%6.1f  H %5.1f/%6.1f  S %.2f", i, m.kick.rise, m.kick.peak,
                               m.mid.rise, m.mid.peak, m.hat.rise, m.hat.peak, m.sustain))
                }
            }
        }
        log(String(format: "Groove A: %d Schritte ab Beat %.0f · Kick %@ · Snare %@ · Hats zu %@ · offen %@ · %.2f ms",
                   p.steps, g.slots[0].startBeat, "\(p.steps(.kick))", "\(p.steps(.snare))", "\(p.steps(.closedHat))",
                   "\(p.steps(.openHat))", ms))
        for style in GrooveStyle.allCases {
            var o = g.options(mix, g.slots[0]); o.style = style; o.instrument = .both
            let c = GrooveGenerator.clip(p, o)
            let hats = c.notes.filter { $0.channel == o.drumChannel }.map(\.step), bass = c.notes.filter { $0.channel == o.bassChannel }
            guard Set(hats).count == hats.count, Set(hats).isDisjoint(with: p.hatSteps),
                  Set(bass.map(\.step)).count == bass.count else { log("Groove FEHLER: \(style) doppelt belegt"); exit(1) }
            log("Groove \(style.rawValue): \(hats.count) Hats, \(bass.count) Bass-Noten (\(bass.map { Int($0.note) }.prefix(8)))")
        }
        guard let data = g.midiData(mix, 0), let f = try? MIDIFile.parse(data), let clip = g.slots[0].clip else { log("Groove FEHLER: .mid"); exit(1) }
        let notes = f.tracks.reduce(0) { $0 + $1.notes.count }
        guard notes == clip.notes.count, abs((f.bpm ?? 0) - g.slots[0].bpm) < 0.01 else {
            log("Groove FEHLER: .mid \(notes) Noten statt \(clip.notes.count), \(f.bpm ?? 0) BPM"); exit(1)
        }
        log(String(format: "Groove .mid: %d Bytes, %d Spuren, %d Noten, %.2f BPM", data.count, f.tracks.count, notes, f.bpm ?? 0))

        // laufend: versteckte Quelle, eigener Eingang
        final class Box: @unchecked Sendable { let lock = NSLock(); var got: [(stamp: UInt64, at: UInt64, status: UInt8)] = [] }
        let box = Box()
        g.start(mix, 0)
        guard g.running == 0, let out = g.out, out.listen({ stamp, st, _, _ in
            let now = mach_absolute_time()
            box.lock.withLock { box.got.append((stamp, now, st)) }
        }) else { log("Groove FEHLER: MIDI startet nicht (\(g.out?.lastError ?? "-"))"); exit(1) }
        try? await Task.sleep(for: .seconds(2))
        // Raster der Clock: Beat zum Zeitstempel über den letzten Clock-Stempel
        guard let st = core.engine.clockStamp else { log("Groove FEHLER: keine Clock"); exit(1) }
        let spb = 60 / core.clockTempo, second = Double(LinkSession.hostTicks(seconds: 1))
        g.stop()
        out.unlisten()
        let got = box.lock.withLock { box.got }
        let ons = got.filter { $0.status & 0xF0 == 0x90 }
        var worst = 0.0, lead = [Double]()
        for e in ons {
            let beat = st.beat + Double(Int64(bitPattern: e.stamp &- st.hostTime)) / second / spb
            let off = abs(beat * 4 - (beat * 4).rounded()) / 4 * spb
            worst = max(worst, off)
            lead.append(Double(Int64(bitPattern: e.stamp &- e.at)) / second * 1000)
        }
        lead.sort()
        log(String(format: "Groove MIDI 2 s: %d Note-Ons, %d Ereignisse gesamt · Abstand zum 16tel-Raster der Clock max %.3f ms · Vorlauf %.1f–%.1f ms",
                   ons.count, got.count, worst * 1000, lead.first ?? 0, lead.last ?? 0))
        let expected = Int(2 / (spb * clip.beats) * Double(clip.notes.count))
        guard ons.count >= expected / 2, worst < 0.002, g.running == nil else {
            log("Groove FEHLER: \(ons.count) Note-Ons (erwartet ~\(expected)), Raster \(worst * 1000) ms"); exit(1)
        }
        if !wasPlaying { core.togglePlay(0) }
    }

    /// Collection-Datei schreiben (Hotcues, Playlists, neuer Eintrag, Umbenennung) auf einer Kopie der Collection im
    /// Temp-Ordner. Die echte Datei wird nur gelesen; der Schreibschutz im Selbsttest muss sie ablehnen
    static func nmlProbe() async {
        let real = LibraryStore.defaultNML
        guard !CollectionWriter.writeAllowed(real) else { log("NML-Rundreise: FEHLER Schreibschutz lässt die echte Collection zu"); exit(1) }
        guard FileManager.default.fileExists(atPath: real.path) else { log("NML-Rundreise: übersprungen (keine Collection)"); return }
        let report = await Task.detached(priority: .utility) { () -> String in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("minos741-nml-\(UUID().uuidString.prefix(8))")
            defer { try? fm.removeItem(at: dir) }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("collection-copy.nml")
                try fm.copyItem(at: real, to: url)
                let text = try String(contentsOf: url, encoding: .utf8)
                let index = NMLEntryIndex(nmlText: text)
                let c = try NMLParser.parse(url: url)
                guard let t = c.tracks.first(where: { $0.hotcues.contains { $0.kind != .grid } && !$0.locked }),
                      let m = c.tracks.first(where: { $0.key != t.key && $0.key.hasSuffix(".mp3") }) else { return "FEHLER keine passenden Tracks" }
                var job = CollectionWriter.Job()
                var hot = t.hotcues.filter { $0.hotcue != 7 }
                hot.append(Cue(name: "Loop", kind: .loop, startMs: 1000, lengthMs: 1875, hotcue: 7))
                job.cues[t.key] = TrackEdit(hotcues: hot)
                job.moves[m.key] = NMLLocation(volume: String(m.key.prefix { $0 != "/" }), volumeID: String(m.key.prefix { $0 != "/" }),
                                               dir: String(m.key[m.key.range(of: "/:")!.lowerBound..<m.key.range(of: "/:", options: .backwards)!.upperBound]),
                                               file: String((m.path as NSString).lastPathComponent.dropLast(4)) + ".m4a")
                var loop = t
                loop.key = String(t.key.dropLast((t.path as NSString).pathExtension.count + 1)) + " [tool-loop 1].m4a"
                job.newEntries = [loop]
                job.playlists = [.playlist("Preparation", c.tracks.prefix(3).map(\.key)), .folder("History", [.playlist("History test", [t.key, m.key])])]
                job.expected = FileStamp(url: url)
                let t0 = CACurrentMediaTime()
                let r = try CollectionWriter.write(url: url, job: job, index: index, backupDir: dir.appendingPathComponent("Backup MINOS-741"))
                let ms = (CACurrentMediaTime() - t0) * 1000
                let after = try NMLParser.parse(url: url)
                let byKey = Dictionary(after.tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                let newKey = job.moves[m.key]!.key
                let cueOK = byKey[t.key]?.hotcues.contains { $0.hotcue == 7 && $0.kind == .loop && abs($0.lengthMs - 1875) < 0.001 } == true
                // eigener Ordner nach Namen (Playlists, die danach in der Collection angelegt wurden, stehen dahinter)
                let own = after.root.children.first { $0.name == CollectionWriter.ownFolder }
                let ok = r.changed && r.backup != nil && after.tracks.count == c.tracks.count + 1 && byKey[loop.key] != nil && cueOK
                    && byKey[newKey] != nil && byKey[m.key] == nil && own?.name == CollectionWriter.ownFolder
                    && own?.children.first?.trackKeys.count == 3 && own?.children.last?.children.first?.trackKeys == [t.key, newKey]
                // außerhalb der geänderten Stellen gleich: alle übrigen ENTRY-Blöcke unverändert
                let out = try String(contentsOf: url, encoding: .utf8)
                let idx2 = NMLEntryIndex(nmlText: out)
                let changedBlocks = index.raw.filter { k, b in k != t.key && k != m.key && idx2.raw[k] != b }.count
                // zweiter Lauf (Index der neuen Datei): gleicher Stand -> nichts geschrieben
                var again = CollectionWriter.Job()
                again.cues = job.cues
                again.newEntries = job.newEntries
                again.playlists = [.playlist("Preparation", c.tracks.prefix(3).map(\.key)), .folder("History", [.playlist("History test", [t.key, newKey])])]
                let r2 = try CollectionWriter.write(url: url, job: again, index: idx2, backupDir: nil)
                return String(format: "%@ · schreiben %.0f ms · %d Tracks +%d · Cues %@ · umbenannt %@ · Playlists %@ · andere Blöcke geändert %d · zweiter Lauf %@",
                              ok && changedBlocks == 0 && !r2.changed ? "OK" : "FEHLER", ms, c.tracks.count, r.added.count,
                              cueOK ? "ok" : "fehlen", byKey[newKey] != nil ? "ok" : "fehlt", own?.name ?? "-", changedBlocks,
                              r2.changed ? "schrieb erneut" : "unverändert")
            } catch {
                return "FEHLER \(error)"
            }
        }.value
        log("NML-Rundreise (Kopie): \(report)")
        if report.hasPrefix("FEHLER") { exit(1) }
    }

    /// DAW-Brücke: Testpakete (Clip mit Warp-Markern für die Datei in Deck B, Song mit Position) an den eigenen
    /// Empfänger (Selbsttest: vom System gewählter Port), Modell, Quelle DAW, Streifen-Zuordnung, Grid übernehmen +
    /// Rückgängig, Abmelden
    static func dawBridgeProbe(_ mix: MixModel, store: LibraryStore) async {
        let bridge = DAWBridgeModel.shared, d = 1
        mix.pull()
        guard let t = mix.deck(d).track, mix.deck(d).duration > 30 else { log("DAW-Brücke: übersprungen"); return }
        if bridge.port == 0 { bridge.configure(enabled: true, port: 0) }
        func fail(_ s: String) -> Never { log("DAW-Brücke: \(s)"); log("DAW-BRÜCKE FALSCH"); exit(1) }
        guard bridge.port > 0 else { fail("Empfänger nicht gestartet (\(bridge.startError ?? "-"))") }
        let bpm = 125.0, beat = 60 / bpm, anchor = 0.3
        let clip: [String: Any] = ["v": 1, "t": "clip", "id": "selftest", "track": 0, "trackName": "Selbsttest", "name": "Clip",
                                   "file": t.path, "warping": true,
                                   "markers": [[0, anchor], [64, anchor + 64 * beat], [64.03125, anchor + 64.03125 * beat]],
                                   "loop": [0, 16], "looping": true, "start": 0, "end": 64, "playing": true, "selected": false, "where": "session"]
        let song: [String: Any] = ["v": 1, "t": "song", "seq": 1, "tempo": bpm, "playing": true, "beat": 0, "sig": 4,
                                   "clips": ["selftest"], "pos": ["selftest": [1, 8.0]]]
        let before = mix.deck(d).grid, edited = mix.deck(d).gridEdited
        try? await Task.sleep(for: .seconds(1))   // Hauptthread nach den vorigen Schritten zur Ruhe (Übergabe messen)
        let t0 = CACurrentMediaTime()
        for p in [clip, song] {
            guard let data = try? JSONSerialization.data(withJSONObject: p), DAWBridgeReceiver.send(data, port: bridge.port) else { fail("senden") }
        }
        while bridge.clip(deck: d)?.id != "selftest", CACurrentMediaTime() - t0 < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        let latency = (CACurrentMediaTime() - t0) * 1000
        guard bridge.clip(deck: d)?.id == "selftest" else { fail("Clip nicht beim Deck angekommen") }
        guard let dt = store.track(DAWBridgeModel.keyPrefix + "selftest"), abs(dt.bpm - bpm) < 1e-6,
              abs((dt.gridAnchorMs ?? 0) - anchor * 1000) < 1e-6, store.tracks(for: .daw).count == 1 else { fail("Quelle DAW: Track/Grid falsch") }
        let pos = bridge.position(of: "selftest") ?? 0
        guard pos >= 8, pos < 8 + 0.5 * bpm / 60 + 1e-9 else { fail("Position \(pos)") }
        // Dauerbetrieb: 20 Song-Pakete wie im 100-ms-Takt (hier alle 10 ms), nur Positionen
        let n0 = bridge.deliverMs.count
        for i in 0..<20 {
            var s = song
            s["seq"] = 2 + i
            s["pos"] = ["selftest": [1, 8.0 + Double(i) * 0.2]]
            if let data = try? JSONSerialization.data(withJSONObject: s) { DAWBridgeReceiver.send(data, port: bridge.port) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        let steady = bridge.deliverMs.suffix(from: min(n0, bridge.deliverMs.count)).sorted()
        bridge.applyGrid(deck: d, mix: mix)
        mix.pull()
        guard let g = mix.deck(d).grid, abs(g.bpm - bpm) < 1e-9, abs(g.anchor - anchor) < 1e-9, mix.deck(d).gridEdited else {
            fail("Grid nicht übernommen: \(String(describing: mix.deck(d).grid))")
        }
        UndoStack.shared.undo()
        mix.pull()
        guard mix.deck(d).grid == before, mix.deck(d).gridEdited == edited else { fail("Rückgängig stellt das Grid nicht her") }
        guard let bye = try? JSONSerialization.data(withJSONObject: ["v": 1, "t": "bye"]) else { fail("bye") }
        DAWBridgeReceiver.send(bye, port: bridge.port)
        let t1 = CACurrentMediaTime()
        while !bridge.clips.isEmpty, CACurrentMediaTime() - t1 < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        guard bridge.clips.isEmpty, bridge.deckClip[d] == nil, store.tracks(for: .daw).isEmpty else { fail("Abmelden leert die Liste nicht") }
        log(String(format: "DAW-Brücke: Port %d · Clip am Deck nach %.1f ms · Grid %.2f BPM / Anker %.3f s übernommen + rückgängig ok · Position %.2f Beats · Song-Pakete: %d Übergaben, Hauptthread median %.3f ms, max %.3f ms",
                   Int(bridge.port), latency, bpm, anchor, pos, steady.count, steady.isEmpty ? 0 : steady[steady.count / 2], steady.last ?? 0))
    }

    /// Plugin-Ketten und Master-Bus, stumm (nur Pegel). FX 4 auf Deck A: AUHipass (3 kHz) -> AUPeakLimiter (+20 dB),
    /// dann getauscht (nichtlinear: anderes Ergebnis). Master-Bus mit AUPeakLimiter (−20 dB vor dem Limiter): Pegel des
    /// Master-Paars (vor MAIN) ändert sich, das Vorhören (eigenes Paar, nach dem Master) nicht. Danach alles zurück
    static func chainProbe(_ mix: MixModel, tracks c: [Track]) async {
        let core = mix.core, engine = mix.engine, master = MixController.masterBus
        let wasExternal = core.snapshot().externalMixer
        core.setExternalMixer(false)   // der Master-Bus braucht den Summenpunkt (MAIN steht auf 0: stumm)
        if !core.snapshot().decks[0].playing { core.togglePlay(0) }
        let assigned = core.snapshot().decks[0].fxAssign[3]
        if !assigned { core.toggleFXAssign(0, 3) }
        func average(_ f: () -> Float) async -> Float {
            var acc: Float = 0
            for _ in 0..<16 { try? await Task.sleep(for: .milliseconds(50)); acc += f() }
            return acc / 16
        }
        func loaded(_ b: Int, _ n: Int) async -> Bool {
            for _ in 0..<300 where (0..<n).contains(where: { core.pluginInstance(b, slot: $0) == nil }) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return (0..<n).allSatisfy { core.pluginInstance(b, slot: $0) != nil }
        }
        let dry = await average { engine.levels[0].rms }
        core.setSlots(3, [])
        core.addSlot(3, id: "aufx:hpas:appl")
        core.addSlot(3, id: "aufx:lmtr:appl")
        let ok = await loaded(3, 2)
        core.pluginInstance(3, slot: 0)?.set(0, 3000)   // Hochpass: Grenzfrequenz (Deck A rechnet mit diesen Instanzen)
        core.pluginInstance(3, slot: 1)?.set(2, 20)     // Limiter: Vorverstärkung
        core.updateFX(3) { for i in $0.slots.indices { $0.slots[i].on = true }; $0.dryWet = 1 }
        try? await Task.sleep(for: .milliseconds(600))
        let hpLim = await average { engine.levels[0].rms }
        let t0 = CACurrentMediaTime()
        core.moveSlot(3, slot: 1, by: -1)
        let moveMs = (CACurrentMediaTime() - t0) * 1000
        try? await Task.sleep(for: .milliseconds(600))
        let limHp = await average { engine.levels[0].rms }
        let lat = core.rackLatency(3).total
        core.setSlots(3, [])
        if !assigned { core.toggleFXAssign(0, 3) }
        let chainOK = ok && hpLim > limHp * 1.5
        log(String(format: "Plugin-Kette FX4 auf A: trocken %.3f · Hochpass>Limiter %.3f · Limiter>Hochpass %.3f (getauscht in %.2f ms) · Latenz %.1f ms · %@",
                   dry, hpLim, limHp, moveMs, lat * 1000, chainOK ? "OK" : "FAIL"))
        // Master-Bus: Limiter mit −20 dB Vorverstärkung = deutlich leiser; Vorhören läuft daneben
        let pv = mix.previewer
        if let t = c.last { mix.preview(t) }
        for _ in 0..<1500 where mix.previewing == nil && mix.previewLoading != nil { try? await Task.sleep(for: .milliseconds(20)) }
        let m0 = await average { engine.masterLevels.rms }, p0 = await average { pv.level.rms }
        core.addSlot(master, id: "aufx:lmtr:appl")
        let mOK = await loaded(master, 1)
        core.pluginInstance(master, slot: 0)?.set(2, -20)
        core.setMasterFX(on: true, dryWet: 1)
        try? await Task.sleep(for: .milliseconds(600))
        let m1 = await average { engine.masterLevels.rms }, p1 = await average { pv.level.rms }
        core.setMasterFX(on: false)
        try? await Task.sleep(for: .milliseconds(300))
        let m2 = await average { engine.masterLevels.rms }
        core.removeSlot(master, slot: 0)
        mix.stopPreview()
        core.setExternalMixer(wasExternal)
        let previewOK = p0 == 0 || abs(p1 - p0) < max(p0, p1) * 0.5
        let masterOK = mOK && m1 < m0 * 0.5 && m2 > m1 * 1.5 && previewOK
        log(String(format: "Master-Bus (Limiter −20 dB): Master-Pegel aus %.3f · an %.3f · wieder aus %.3f · Vorhören %.3f / %.3f · %@",
                   m0, m1, m2, p0, p1, masterOK ? "OK" : "FAIL"))
        if !chainOK || !masterOK { log("FEHLER Plugin-Kette / Master-Bus"); exit(1) }
    }
}

extension SelfTest {
    /// Insert-Slots, stumm (nur Pegel) auf FX 3 / Deck A: ein Slot Delay, dann drei (Delay · Filter · Reverb), Umordnen im
    /// Betrieb (Reverb nach vorn), Plugin-Slot mit Apples AUDelay isoliert (Dienst des Systems). Danach FX 3 leer
    static func insertProbe(_ mix: MixModel) async {
        let core = mix.core, engine = mix.engine, u = 2, plug = "aufx:dely:appl"
        if !core.snapshot().decks[0].playing { core.togglePlay(0) }
        let assigned = core.snapshot().decks[0].fxAssign[u]
        if !assigned { core.toggleFXAssign(0, u) }
        func average() async -> (rms: Float, peak: Float) {
            var acc: Float = 0, pk: Float = 0
            for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(50)); let l = engine.levels[0]; acc += l.rms; pk = max(pk, l.peak) }
            return (acc / 12, pk)
        }
        func ids() -> [String] { core.snapshot().fx[u].slots.map(\.id) }
        var fails: [String] = []
        core.setSlots(u, [])
        let dry = await average()
        core.addSlot(u, id: "DELAY")
        core.updateFX(u) { $0.slots[0].on = true; $0.slots[0].params["feedback"] = 0.6; $0.dryWet = 1 }
        try? await Task.sleep(for: .milliseconds(400))
        let one = await average()
        if ids() != ["DELAY"] { fails.append("1 Slot: \(ids())") }
        core.addSlot(u, id: "FILTER")
        core.addSlot(u, id: "REVERB")
        if core.addSlot(u, id: "DELAY") { fails.append("zweites DELAY angenommen") }
        core.updateFX(u) { $0.slots[1].on = true; $0.slots[1].params["cutoff"] = 0.85; $0.slots[2].on = true; $0.slots[2].mix = 0.6 }
        try? await Task.sleep(for: .milliseconds(400))
        let three = await average()
        if ids() != ["DELAY", "FILTER", "REVERB"] { fails.append("3 Slots: \(ids())") }
        let load0 = engine.takeLoad()
        core.moveSlot(u, from: 2, to: 0)
        let moved = await average()
        let load1 = engine.takeLoad()
        if ids() != ["REVERB", "DELAY", "FILTER"] { fails.append("umgeordnet: \(ids())") }
        if !moved.peak.isFinite || moved.peak > 4 || moved.rms <= 0 { fails.append(String(format: "nach dem Umordnen Pegel %.3f / Spitze %.3f", moved.rms, moved.peak)) }
        // Plugin-Slot isoliert (nur im Speicher, der Selbsttest speichert keine Einstellungen)
        core.pluginCatalog.setIsolation(plug, true)
        core.addSlot(u, id: plug)
        for _ in 0..<400 where core.pluginInstance(u, slot: 3) == nil && core.snapshot().pluginErrors[u] == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let inst = core.pluginInstance(u, slot: 3)
        core.setSlotOn(u, slot: 3, true)
        try? await Task.sleep(for: .milliseconds(400))
        let withPlug = await average()
        let failures = inst?.renderFailures.blocks ?? 0
        if inst == nil { fails.append("AUDelay lädt nicht: \(core.snapshot().pluginErrors[u] ?? "-")") }
        else if inst?.outOfProcess != true { fails.append("AUDelay läuft nicht isoliert") }
        core.pluginCatalog.setIsolation(plug, nil)
        core.setSlots(u, [])
        if !assigned { core.toggleFXAssign(0, u) }
        log(String(format: "Insert-Slots FX3 auf A: trocken %.3f · DELAY %.3f · DELAY>FILTER>REVERB %.3f · umgeordnet REVERB>DELAY>FILTER %.3f (Spitze %.2f, über Budget %d/%d) · + AUDelay %@ %.3f (Fehlblöcke %llu) · %@",
                   dry.rms, one.rms, three.rms, moved.rms, moved.peak, load0.overloads, load1.overloads,
                   inst?.outOfProcess == true ? "isoliert" : "im Prozess", withPlug.rms, failures, fails.isEmpty ? "OK" : "FAIL"))
        if !fails.isEmpty { log("FEHLER Insert-Slots: " + fails.joined(separator: " · ")); exit(1) }
    }

    /// Auto-Mix: ein Übergang (8 Takte) von Deck A auf B, an die Phrasengrenze vor dem Outro gesprungen. Geprüft: der
    /// Bass wechselt in der Mitte (vorher A 0 dB / B Kill, danach umgekehrt), der ausgehende Track stoppt am Ende, der
    /// eingehende spielt weiter, die Pegel sind zurückgesetzt
    static func autoMixProbe(_ mix: MixModel, tracks c: [Track]) async -> Bool {
        let core = mix.core, am = mix.autoMix
        func ready(_ d: Int) -> Bool { let s = mix.deck(d); return s.track != nil && !s.loading && s.grid != nil && mix.audio(d) != nil }
        for d in 0..<2 {
            if mix.deck(d).playing { mix.togglePlay(d) }
            mix.updateDeck(d) { $0.eqLow = 0; $0.eqMid = 0; $0.eqHigh = 0; $0.filter = 0; $0.fader = 1 }
        }
        am.transitionBarsOverride = 8   // kurzer Übergang: 8 Takte (nur im Test, die Einstellung bleibt)
        defer { am.transitionBarsOverride = nil }
        guard c.count >= 3 else { log("Auto-Mix: zu wenige Tracks"); return false }
        mix.load(c[0], deck: 0, force: true)
        for _ in 0..<150 where !ready(0) { try? await Task.sleep(for: .milliseconds(100)) }
        guard ready(0), let g = mix.deck(0).grid else { log("FEHLER Auto-Mix: Track A lädt nicht"); return false }
        mix.togglePlay(0)
        // Sprung: 4 Beats vor die Phrasengrenze, die der Übergang nimmt (wie im Modell berechnet)
        let phrase = Double(max(4, mix.prefs.ui.phraseBeats))
        let end = g.beatPosition(at: mix.deck(0).playRange.upperBound)
        guard let b = AutoMixTimeline.outBeat(endBeat: end, now: g.beatPosition(at: mix.position(0)), phraseBeats: phrase, transitionBeats: 32),
              b - 4 > g.beatPosition(at: mix.position(0)) else { log("FEHLER Auto-Mix: kein Ausstieg auf Track A"); return false }
        // Pool: frische Tracks (nicht in der History dieser Sitzung), der laufende Track A ist der Ausgang
        let heard = Set(am.history?.live.map(\.key) ?? [])
        let fresh = c.dropFirst().filter { !heard.contains($0.key) }
        guard fresh.count >= 2 else { log("Auto-Mix: zu wenige frische Tracks"); return false }
        am.start(tracks: Array(fresh.prefix(2)))
        try? await Task.sleep(for: .milliseconds(200))
        core.seek(0, seconds: g.time(ofBeat: b - 4))
        var mixing = false
        for _ in 0..<600 where !mixing {
            try? await Task.sleep(for: .milliseconds(100))
            mixing = am.phase == .mixing
        }
        guard mixing else { log("FEHLER Auto-Mix: kein Übergang gestartet (\(am.phase))"); am.stop(); return false }
        var before = false, swapped = false
        for _ in 0..<400 where am.phase == .mixing {
            let o = mix.deck(0), i = mix.deck(1)
            if o.eqLow == 0 && i.eqLow <= -40 { before = true }
            if o.eqLow <= -40 && i.eqLow == 0 { swapped = true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
        let stopped = !mix.deck(0).playing && mix.deck(0).eqLow == 0 && mix.deck(0).fader == 1
        let running = mix.deck(1).playing
        log("Auto-Mix: Bass vorher \(before) · getauscht \(swapped) · A gestoppt \(stopped) · B spielt \(running) · Phase \(am.phase)")
        am.stop()
        for d in 0..<2 where mix.deck(d).playing { mix.togglePlay(d) }
        for d in 0..<2 { mix.updateDeck(d) { $0.eqLow = 0; $0.eqMid = 0; $0.eqHigh = 0; $0.filter = 0; $0.fader = 1 } }
        return before && swapped && stopped && running
    }

    /// EQ im Kanalzug (intern): Kill auf dem Tief-Regal senkt den Pegel an Deck A, 0 dB stellt ihn wieder her
    static func eqProbe(_ mix: MixModel) async {
        let core = mix.core, s0 = core.snapshot().decks[0]
        if !s0.playing { core.togglePlay(0) }
        func level() async -> Float {
            var acc: Float = 0
            for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(50)); acc += core.engine.levels[0].rms }
            return acc / 12
        }
        core.updateDeck(0) { $0.eqLow = 0; $0.eqMid = 0; $0.eqHigh = 0 }
        try? await Task.sleep(for: .milliseconds(300))
        let flat = await level()
        core.updateDeck(0) { $0.eqLow = -40 }
        try? await Task.sleep(for: .milliseconds(300))
        let killed = await level()
        core.updateDeck(0) { $0.eqLow = 0 }
        try? await Task.sleep(for: .milliseconds(300))
        let back = await level()
        core.updateDeck(0) { $0.eqLow = s0.eqLow; $0.eqMid = s0.eqMid; $0.eqHigh = s0.eqHigh }
        var fails: [String] = []
        // extern ohne „EQ im externen Modus“: der EQ ist aus (das Pult macht ihn), der Kill darf nichts ändern
        let bypass = mix.mixerMode != .internalMixer && !mix.prefs.engine.eqExternal
        if !(flat > 0 && flat.isFinite) { fails.append("kein Pegel") }
        if bypass {
            if abs(killed - flat) > flat * 0.05 { fails.append("EQ wirkt extern, obwohl aus") }
        } else {
            if !(killed < flat * 0.9) { fails.append("Tief-Kill ohne Wirkung") }
            if !(back > killed * 1.1) { fails.append("nach 0 dB kein Pegel") }
        }
        log(String(format: "EQ Deck A%@: flach %.3f · Tief-Kill %.3f · zurück %.3f%@", bypass ? " (extern, EQ aus)" : "", flat, killed, back,
                   fails.isEmpty ? " · OK" : " · " + fails.joined(separator: " · ")))
        if !fails.isEmpty { log("FEHLER EQ: " + fails.joined(separator: " · ")); exit(1) }
    }

    /// gespielte ausblenden (◆ UNGESPIELT): Collection ohne die gespielten Tracks (A + die der Sitzung), Anzahl im Kopf
    /// stimmt, History, RUNNING und Preparation zeigen sie weiter. Gespielt-Markierungen danach wie vorher
    /// Detailleiste: 60 Track-Wechsel (Anzeigen + Zeichnen, ein- und zweizeilige Breite), Hauptthread je Wechsel < 2 ms
    static func detailBarProbe(_ mix: MixModel, store: LibraryStore) {
        let tracks = Array(store.tracks.prefix(60))
        guard tracks.count > 10 else { log("Detailleiste: zu wenige Tracks"); return }
        let ctl = TrackTableController()
        var ms: [Double] = []
        for w in [1200.0, 1700.0] {
            let bar = DetailBarView(frame: NSRect(x: 0, y: 0, width: w, height: DetailBarView.height(width: w)))
            _ = bar.measure(tracks[0], table: ctl)   // erste Zeichnung (Schriften) nicht mitzählen
            for t in tracks.dropFirst() { ms.append(bar.measure(t, table: ctl)) }
        }
        ms.sort()
        let med = ms[ms.count / 2], p95 = ms[Int(Double(ms.count) * 0.95)]
        let ok = med < 2
        log(String(format: "Detailleiste: %d Wechsel, median %.2f ms, p95 %.2f ms, max %.2f ms · %@", ms.count, med, p95, ms.last ?? 0, ok ? "OK" : "FAIL"))
        if !ok { log("DETAILLEISTE FALSCH"); exit(1) }
    }

    static func hidePlayedProbe(_ mix: MixModel, store: LibraryStore, browser: BrowserState, tracks c: [Track]) async {
        guard let history = browser.history else { log("UNGESPIELT: keine History"); log("UNGESPIELT FALSCH"); exit(1) }
        let played0 = history.played, live0 = history.live.count
        history.setPlayed(played0.union([c[0].key]))
        defer { history.setPlayed(played0) }
        let played = history.played, seps = mix.prefs.ui.tagSeparators
        let pane = BrowserPaneModel(name: "Selbsttest")
        let all = pane.rows(from: store, history: history, separators: seps)
        let t0 = CACurrentMediaTime()
        let shown = pane.rows(from: store, history: history, separators: seps, hidePlayed: true)
        let ms = (CACurrentMediaTime() - t0) * 1000, hidden = pane.hiddenCount
        let expected = all.filter { played.contains($0.key) }.count
        pane.source = .preparation
        let prep = pane.rows(from: store, history: history, separators: seps).count
        let prepHidden = pane.rows(from: store, history: history, separators: seps, hidePlayed: true).count
        let exempt = [BrowserSource.historyLive, .running, .preparation].allSatisfy {
            BrowserPaneModel.hiddenKeys(source: $0, played: played, hidePlayed: true) == nil
        }
        let ok = expected >= 1 && shown.count == all.count - expected && hidden == expected && pane.hiddenCount == 0 && prep == prepHidden
            && !shown.contains { played.contains($0.key) } && exempt && history.live.count == live0
        log(String(format: "UNGESPIELT: Collection %d -> %d (%d gespielt ausgeblendet, %.1f ms) · Preparation %d = %d · History %d Einträge · %@",
                   all.count, shown.count, expected, ms, prep, prepHidden, history.live.count, ok ? "OK" : "FAIL"))
        if !ok { log("UNGESPIELT FALSCH"); exit(1) }
    }

    /// Vorbereiten auf Deck A (Dateien nur im Test-Ordner): Spitze messen, +3 dB -> RENDER (Spitze × 1,41 bzw. bis 0 dBFS
    /// begrenzt, Länge, Format wie die Quelle, LOUDNESS nachgeführt), A-B-A (16 Beats heraus, Vorschau vor der Naht),
    /// RENDER Schnitt + Amp, SPLIT am Takt (Längen, Grid von Teil 2), JOIN mit dem Track von Deck B (Länge, Grid).
    /// Danach alles zurück, Dateien gelöscht
    static func prepareProbe(_ mix: MixModel) async {
        let d = 0
        mix.pull()
        let s0 = mix.deck(d)
        guard let t0 = s0.track, let g = s0.grid, g.bpm > 0, s0.duration > 120 else { log("Vorbereiten: übersprungen (Deck A ohne Grid)"); return }
        let wasEditing = mix.editing(d), u = UndoStack.shared, n0 = u.done.count
        var files: [String] = []
        func settle() async {
            for _ in 0..<500 where mix.editSession(d)?.rendering == true || mix.prepState(d).measuring { try? await Task.sleep(for: .milliseconds(20)) }
            mix.pull()
        }
        func job() async -> [Track] {
            for _ in 0..<6000 where CutJob.running { try? await Task.sleep(for: .milliseconds(20)) }
            files += CutJob.lastTracks.map(\.path)
            return CutJob.lastTracks
        }
        func peakAndFrames(_ path: String) async -> (Float, Int, Double) {
            await Task.detached {
                guard let s = try? AudioCutWriter.source(url: URL(fileURLWithPath: path), deck: nil) else { return (0, 0, 0) }
                return (AudioCutWriter.peak(s.channels, frames: s.frames), s.frames, s.sampleRate)
            }.value
        }
        mix.prepareRowAppeared(d)
        await settle()
        guard let session = mix.editSession(d) else { log("Vorbereiten FALSCH: keine Sitzung"); exit(1) }
        if !session.shown.isPlain || session.shown.segments.count > 1 { mix.editReset(d); await settle() }
        mix.prepareAmpReset(d)
        mix.prepareAnalyse(d)
        await settle()
        let deckPeak = mix.prepState(d).peak ?? -1
        // +3 dB -> RENDER
        let (srcPeak, srcFrames, rate) = await peakAndFrames(t0.path)
        mix.prepareAmp(d, add: 3)
        let want = Amplify.limit(3, peak: srcPeak, allowClipping: false)
        CutJob.lastTracks = []
        let c0 = CACurrentMediaTime()
        mix.prepareRender(d, load: false)
        let amp = await job()
        let ampSecs = CACurrentMediaTime() - c0
        guard let a = amp.first else { log("Vorbereiten FALSCH: kein Ergebnis für AMP"); exit(1) }
        let (outPeak, outFrames, _) = await peakAndFrames(a.path)
        let ratio = Double(outPeak / max(srcPeak, 1e-9))
        let fmt = AudioCutWriter.format(matching: URL(fileURLWithPath: t0.path))
        let ampOK = outFrames == srcFrames && (want.limited ? outPeak <= 1 && outPeak > 0.99 : abs(ratio - Amplify.factor(db: 3)) < 2e-3)
            && a.path.hasPrefix(CutJob.selfTestDirectory.path) && (a.path as NSString).pathExtension == fmt.ext
            && (t0.perceivedDb == nil || abs((a.perceivedDb ?? 99) - (t0.perceivedDb! - (CutJob.lastGain ?? 0))) < 1e-6)
        log(String(format: "Vorbereiten AMP +3 dB: Spitze Deck %.4f / Datei %.4f -> %.4f (× %.4f%@) · %d / %d Frames · %@ · %.2f s · %@",
                   deckPeak, srcPeak, outPeak, ratio, want.limited ? ", auf 0 dBFS begrenzt" : "", outFrames, srcFrames,
                   (a.path as NSString).lastPathComponent, ampSecs, ampOK ? "ok" : "FALSCH"))
        // A-B-A: 16 Beats ab dem Takt nahe 40 s
        let b0 = g.time(ofBeat: (g.beatPosition(at: 40) / 4).rounded() * 4), len = 16 * g.beat
        mix.setRange(d, TrackRange(b0, b0 + len))
        mix.prepareABA(d)
        await settle()
        let dur1 = mix.deck(d).duration, pos1 = mix.position(d)
        let abaOK = mix.editSession(d)?.preview != nil && abs(dur1 - (s0.duration - len)) < 2 / rate
            && abs(pos1 - (b0 - 8 * g.beat)) < 0.25 && mix.range(d) == nil
        log(String(format: "Vorbereiten A-B-A: 16 Beats heraus %.3f -> %.3f s · Vorschau bei %.2f s (Naht %.2f s) · %@",
                   s0.duration, dur1, pos1, b0, abaOK ? "ok" : "FALSCH"))
        // RENDER Schnitt + Amp
        mix.prepareRender(d, load: false)
        let both = await job()
        let (_, bothFrames, _) = await peakAndFrames(both.first?.path ?? "")
        let bothOK = both.first?.title.hasSuffix("[cut amp \(Amplify.label(CutJob.lastGain ?? 0))]") == true
            && abs(Double(bothFrames) - Double(srcFrames) + len * rate) <= 2
        log(String(format: "Vorbereiten RENDER Schnitt + Amp: %@ · %d Frames (soll %.0f) · %@", both.first?.fileName ?? "-", bothFrames,
                   Double(srcFrames) - len * rate, bothOK ? "ok" : "FALSCH"))
        // SPLIT am Takt nahe 60 s (gespielte Liste)
        mix.prepareAmpReset(d)
        mix.core.seek(d, seconds: g.time(ofBeat: (g.beatPosition(at: 60) / 4).rounded() * 4) + 0.3 * g.beat)
        mix.pull()
        let at = SplitPlan.point(range: nil, position: mix.position(d), grid: mix.deck(d).grid, duration: dur1) ?? -1
        mix.prepareSplit(d)
        let parts = await job()
        var splitOK = parts.count == 2
        var lens: [Int] = []
        for p in parts { lens.append(await peakAndFrames(p.path).1) }
        if parts.count == 2 {
            let ga = BeatGrid(track: parts[1])
            splitOK = abs(Double(lens[0]) - at * rate) <= 2 && abs(Double(lens[0] + lens[1]) - dur1 * rate) <= 3
                && (ga.map { $0.anchor < 1e-3 } ?? false) && parts[0].title.hasSuffix("[part 1]") && parts[1].title.hasSuffix("[part 2]")
        }
        log(String(format: "Vorbereiten SPLIT bei %.3f s: %@ Frames (zusammen %d, soll %.0f) · Grid Teil 2 ab %.4f s · %@", at,
                   lens.map(String.init).joined(separator: " + "), lens.reduce(0, +), dur1 * rate,
                   parts.count == 2 ? (BeatGrid(track: parts[1])?.anchor ?? .nan) : .nan, splitOK ? "ok" : "FALSCH"))
        // JOIN mit dem Track von Deck B
        var joinOK = true
        if let second = mix.deck(1).track, second.key != t0.key, FileManager.default.fileExists(atPath: second.path) {
            let b = mix.edits.edit(for: second.key)?.apply(to: second) ?? second
            mix.prepareJoin(d, with: second)
            let joined = await job()
            let (_, jFrames, _) = await peakAndFrames(joined.first?.path ?? "")
            let bInfo = await peakAndFrames(second.path)
            let bDur = Double(bInfo.1) / max(1, bInfo.2)
            let plan = JoinPlan.plan(durationA: dur1, gridA: mix.deck(d).grid, durationB: bDur, gridB: BeatGrid(track: b),
                                     matchTempo: mix.prefs.ui.prepJoinMatchTempo)
            let jg = joined.first.flatMap { BeatGrid(track: $0) }
            joinOK = abs(Double(jFrames) - plan.duration * rate) <= 3 + plan.duration * rate * 1e-5
                && jg.map { abs($0.bpm - g.bpm) < 1e-9 } ?? false
            log(String(format: "Vorbereiten JOIN mit %@ (%.2f BPM): Naht %.3f s, B ab %.3f s, Tempo × %.4f%@ · %d Frames (soll %.0f) · %@ · %@",
                       second.title, b.bpm, plan.joint, plan.startB, plan.speed, plan.tempoMismatch ? " (verschieden)" : "",
                       jFrames, plan.duration * rate, CutJob.lastNote ?? "-", joinOK ? "ok" : "FALSCH"))
        } else {
            log("Vorbereiten JOIN: übersprungen (Deck B ohne anderen Track)")
        }
        // zurück
        while u.done.count > n0 { u.undo() }
        await settle()
        let back = mix.core.trackAudio(d) === session.source && abs(mix.deck(d).duration - s0.duration) < 1e-6
        mix.prepareAmpReset(d)
        mix.setRange(d, nil)
        mix.prepareRowDisappeared(d)
        mix.setEditing(d, wasEditing)
        mix.pull()
        for f in files { try? FileManager.default.removeItem(atPath: f) }
        let ok = ampOK && abaOK && bothOK && splitOK && joinOK && back
        log("Vorbereiten: Rückgängig -> Original \(back) · \(files.count) Dateien gelöscht · " + (ok ? "ok" : "FALSCH"))
        if !ok { log("Vorbereiten FALSCH"); exit(1) }
    }

    /// Playlist-Baum (nur im Temp-Ordner des Selbsttests): Ordner in Ordner, Playlist mit Tracks, Smartlist mit
    /// Regelzeile gegen die Collection, Verschieben + Rückgängig, Reihenfolge, Entfernen, Spiegel für die
    /// Collection-Datei, Datei-Rundreise. Danach wieder der Stand vorher, Temp-Ordner weg
    static func playlistTreeProbe(store: LibraryStore) async {
        func fail(_ s: String) -> Never { log("Playlist-Baum: \(s)"); log("PLAYLIST-BAUM FALSCH"); exit(1) }
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard PlaylistFile.url.resolvingSymlinksInPath().path.hasPrefix(tmp) else { fail("Datei nicht im Temp-Ordner: \(PlaylistFile.url.path)") }
        let before = store.playlists
        let genres = Dictionary(store.tracks.map { ($0.genre, 1) }, uniquingKeysWith: +).filter { !$0.key.isEmpty }
        guard let genre = genres.max(by: { $0.value < $1.value })?.key, store.tracks.count >= 5 else { log("Playlist-Baum: übersprungen (keine Genres)"); return }
        let folder = store.addOwn(.folder, into: nil, name: "ST Ordner")
        let sub = store.addOwn(.folder, into: folder.id, name: "ST Unter")
        let keys = store.tracks.prefix(5).map(\.key)
        let pl = store.addOwn(.playlist, into: sub.id, name: "ST Playlist", tracks: Array(keys))
        let sm = store.addOwn(.smartlist, into: folder.id, name: "ST Smartlist", rules: SmartRules(rules: [SmartRule(.genre, .contains, genre)]))
        let t0 = CACurrentMediaTime()
        let hits = store.tracks(for: .own(OwnRef(sm)))
        let ms = (CACurrentMediaTime() - t0) * 1000
        let want = store.tracks.filter { SmartRules.contains(Track.fold($0.genre), Track.fold(genre)) }.count
        guard hits.count == want, want > 0 else { fail("Smartlist Genre enthält „\(genre)“: \(hits.count) statt \(want)") }
        guard store.tracks(for: .own(OwnRef(pl))).map(\.key) == Array(keys) else { fail("Playlist-Tracks falsch") }
        guard store.playlists.parent(of: pl.id) == .some(sub.id), store.playlists.isDescendant(pl.id, of: folder.id) else { fail("Ordner in Ordner") }
        store.editPlaylists("ST verschieben") { $0.move(pl.id, into: nil) }
        guard store.playlists.parent(of: pl.id) == .some(nil) else { fail("Verschieben nach oben") }
        UndoStack.shared.undo()
        guard store.playlists.parent(of: pl.id) == .some(sub.id) else { fail("Rückgängig nach dem Verschieben") }
        store.editPlaylists("ST Reihenfolge") { $0.moveTracks([keys[4]], in: pl.id, to: 0) }
        store.removeFromPlaylist([keys[0]], pl.id)
        let order = store.playlists.item(pl.id)?.tracks ?? []
        guard order == [keys[4], keys[1], keys[2], keys[3]] else { fail("Reihenfolge / Entfernen: \(order.count) Tracks") }
        // Spiegel für `$ROOT/MINOS-741/Playlists`: Ordner + Playlists, ohne Smartlists
        guard case let .folder(name, kids)? = store.ownPlaylists().last, name == LibraryStore.ownPlaylistsFolder,
              kids.contains(.folder("ST Ordner", [.folder("ST Unter", [.playlist("ST Playlist", order)])])) else { fail("Spiegel für die Collection-Datei") }
        PlaylistFile.flush()
        guard let d = try? Data(contentsOf: PlaylistFile.url), let back = try? PlaylistTree.decode(d), back == store.playlists else { fail("Datei-Rundreise") }
        store.editPlaylists("ST löschen") { $0.remove(folder.id) }
        guard !store.playlists.contains(sm.id), !store.playlists.contains(pl.id) else { fail("Ordner löschen nimmt den Inhalt nicht mit") }
        store.playlists = before
        UndoStack.shared.clearAll()
        PlaylistFile.flush()
        PlaylistFile.removeSelfTestDir()
        log(String(format: "Playlist-Baum: Ordner in Ordner, Playlist %d Tracks, Smartlist Genre enthält „%@“ %d Treffer (%.1f ms über %d Tracks), Verschieben + Rückgängig, Reihenfolge, Spiegel, Datei-Rundreise · OK",
                   order.count, genre, hits.count, ms, store.tracks.count))
    }

    /// Wellenform-Kacheln von Deck A (Stil 3-Band, Preset der Einstellungen): Zeit je Kachel (1024 × 180 pt @2×) bei
    /// 4 s und 1,5 s je Seite (1 Block je Gerätepixel bzw. Spalten zwischen den Block-Mitten interpoliert)
    static func waveTileProbe(_ mix: MixModel) {
        guard let audio = mix.core.trackAudio(0), audio.duration > 20 else { log("Wellenform-Kacheln: Deck A leer – übersprungen"); return }
        let wf = RenderedWaveform.render(audio, style: .blend, palette: mix.prefs.ui.waveformPalette, preset: mix.wavePreset)
        var parts: [String] = []
        for (span, label) in [(4.0, "4 s"), (1.5, "1,5 s")] {
            let pps = 1200 / (span * 2), n = 4, t0 = Date()
            for i in 0..<n { _ = WaveLayerNSView.renderTile(i + 1, chunks: wf.chunks, raster: wf.raster, pps: pps, h: 180, tw: 1024, scale: 2) }
            parts.append(String(format: "%@: %.1f ms", label, Date().timeIntervalSince(t0) * 1000 / Double(n)))
        }
        log("Wellenform-Kacheln (1024 × 180 pt @2×, je Kachel): " + parts.joined(separator: " · "))
    }

    /// Wellenform-Presets (Datei nur im Temp-Ordner): eingebautes kopieren, Änderung an einem eingebauten legt eine
    /// Kopie an, umbenennen, Datei-Rundreise; Trennfrequenz Tief 250 Hz -> Deck A wird im Hintergrund nachanalysiert
    /// (andere Hüllkurven als die der Datei); löschen, Auswahl wie vorher
    static func wavePresetProbe(_ mix: MixModel) async {
        func fail(_ s: String) -> Never { log("Wellenform-Presets: \(s)"); log("WELLENFORM-PRESETS FALSCH"); exit(1) }
        let store = mix.wavePresets
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard store.url.resolvingSymlinksInPath().path.hasPrefix(tmp) else { fail("Datei nicht im Temp-Ordner: \(store.url.path)") }
        let before = mix.prefs.ui.wavePreset, n0 = store.list.custom.count
        defer { mix.prefs.ui.wavePreset = before }
        mix.selectWavePreset("blend.d")
        guard let copy = mix.copyWavePreset(), let c = store.list.preset(copy), !c.builtIn, c.base == "blend.d",
              c.look == WavePresets.builtIn[3].look, mix.prefs.ui.wavePreset == copy else { fail("Kopieren") }
        mix.selectWavePreset("blend.a")
        mix.editWavePreset { $0.analysis.low = 250 }
        let edited = mix.wavePreset
        guard !edited.builtIn, edited.id != "blend.a", edited.analysis.low == 250, edited.base == "blend.a",
              WavePresets.builtIn[0].analysis == .standard, store.list.custom.count == n0 + 2 else { fail("Ändern eines eingebauten legt keine Kopie an") }
        store.rename(edited.id, to: "ST Preset")
        mix.editWavePreset { $0.look.gain.mid = 0.7 }
        guard mix.wavePreset.name == "ST Preset", mix.wavePreset.look.gain.mid == 0.7, store.list.custom.count == n0 + 2 else { fail("Umbenennen / eigenes ändern") }
        WavePresetStore.flush()
        guard let d = try? Data(contentsOf: store.url), let back = try? WavePresetList.decodeCustom(d), back == store.list.custom else { fail("Datei-Rundreise") }
        // Nachanalyse von Deck A mit Tief 250 Hz
        if let audio = mix.core.trackAudio(0) {
            let cache = WaveformCache(), t0 = Date()
            var wave: RenderedWaveform?
            while Date().timeIntervalSince(t0) < 20 {
                wave = cache.waveform(for: audio, ui: mix.prefs.ui, preset: mix.wavePreset)
                if wave != nil { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let r = wave?.raster else { fail("keine Wellenform nach der Nachanalyse") }
            guard cache.reanalyzed == 1, r.blend != Array(audio.blend.data.prefix(r.blend.count)) else { fail("Hüllkurven nicht nachgerechnet") }
            log(String(format: "Wellenform-Presets: Nachanalyse Tief 250 Hz %.2f s für %.0f s Audio, fertig nach %.2f s", cache.lastReanalysis, audio.duration, Date().timeIntervalSince(t0)))
        }
        mix.deleteWavePreset()
        guard store.list.preset(edited.id) == nil, mix.prefs.ui.wavePreset == "blend.a" else { fail("Löschen") }
        mix.selectWavePreset(copy)
        mix.deleteWavePreset()
        guard store.list.custom.count == n0, mix.prefs.ui.wavePreset == "blend.d" else { fail("Löschen der Kopie") }
        WavePresetStore.flush()
        store.removeSelfTestDir()
        log("Wellenform-Presets: kopieren, Kopie beim Ändern, umbenennen, Datei-Rundreise, Nachanalyse, löschen · OK")
    }
}
