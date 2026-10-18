import AudioToolbox
import Foundation
import MixCore
import MixProtocol

// MARK: - Zustand (wird als Kopie an die Oberfläche gegeben)

public enum XFAssign: String, CaseIterable, Codable, Sendable { case a = "A", thru = "·", b = "B" }

/// Sync: Beat-Sync zieht auf Phase 0, Fix hält eine von Hand verschobene Phase, Nur Tempo lässt die Phase frei
public enum SyncMode: String, CaseIterable, Codable, Sendable {
    case dynamic = "Dynamisch (zurück auf Phase 0)", fixed = "Fix (verschobene Phase bleibt)", tempo = "Nur Tempo"
}

/// Wohin ein geladener Track springt
public enum LoadPosition: String, CaseIterable, Codable, Sendable {
    case loadCue = "Load-Cue / Grid", start = "Track-Anfang", firstHotcue = "Hotcue 1"
}

public enum CrossfaderCurve: String, CaseIterable, Codable, Sendable {
    case smooth = "Weich", sharp = "Scharf (Cut)"
}

/// Active Loop: gespeicherter Loop greift bei jedem Erreichen des Anfangs oder nur beim ersten Mal nach dem Laden
public enum ActiveLoopMode: String, CaseIterable, Codable, Sendable {
    case always = "Bei jedem Durchlauf", once = "Einmal je Laden"
}

/// Hall-Typ der FX-Units: Allpass-Ring (Standard) oder FDN
public enum ReverbType: String, CaseIterable, Codable, Sendable {
    case classic = "Reverb", fdn = "Reverb (FDN)"
}

/// Einstellungen, die der Steuerkern braucht (alle in ⌘, änderbar)
public struct EnginePrefs: Codable, Equatable, Sendable {
    /// Quant: Sprünge (Hotcue, Loop, Beatjump) halten die Beat-Phase
    public var quantize = true
    /// Snap: gesetzte Cues und Loop-Punkte rasten auf den nächsten Beat
    public var snap = true
    /// Metronom auf welches Kanalpaar (0-basiert)
    public var metronomeChannel = 0
    public var keylockDefault = true
    public var tempoRangeDefault = 8.0
    public var autoGain = true
    /// Headroom und Auto-Gain je Mixer-Modus, Main-Volume im externen Modus optional
    public var headroomInternal = 0.0
    public var headroomExternal = -3.0
    public var autoGainExternal = false
    public var masterVolumeExternal = false
    public var loadPosition = LoadPosition.loadCue
    public var hotcueKeepsPhase = true
    public var bendAmount = 0.04
    public var phaseLock = true
    public var syncMode = SyncMode.dynamic
    /// Link: Versatz in ms (positiv = die anderen Teilnehmer spielen später)
    public var linkOffsetMs = 0.0
    public var trackEndWarning = 30.0
    public var crossfaderCurve = CrossfaderCurve.smooth
    public var eqKill = true
    /// EQ auch im externen Modus (vor dem Kanalpaar). Aus: das Pult macht den EQ, Standard wegen Doppel-EQ
    public var eqExternal = false
    public var channelFilterResonance = 0.6
    public var defaultLoopSize = 4.0
    public var defaultJumpSize = 4.0
    /// Loop-Snap (nur mit Snap): gespeicherten Loop-Cue übernehmen, wenn er bis zu loopSnapCueBeats vor oder hinter
    /// der Position beginnt; sonst auf eine 4-Takt-Grenze innerhalb von loopSnapPhraseBeats
    public var loopSnapCues = true
    public var loopSnapPhrase = true
    public var loopSnapCueBeats = 4.0
    public var loopSnapPhraseBeats = 1.0
    public var delayFeedback = 0.45
    public var fxFilterResonance = 0.4
    /// FX-Belegung je Rack-Kennung ("FILTER > DELAY > REVERB", "DELAY", Plugin-IDs): gilt, sobald eine Unit dieses Rack hat
    public var fxMappings: [String: FXMapping] = [:]
    /// gemerkte Racks (Name → Slots mit Einstellungen bzw. Plugin-Zustand), für jede FX-Unit und den Master-Bus.
    /// Schlüssel wie früher die Plugin-Ketten
    public var pluginChains: [String: [FXSlot]] = [:]
    /// Reverb: Pegel in dB (0 = Hall bei vollem D/W ≈ 4 dB unter dem Track), Helligkeit 0…1, Vorverzögerung in ms
    public var reverbLevelDb = 0.0
    public var reverbBrightness = 0.6
    public var reverbPreDelayMs = 15.0
    public var reverbType = ReverbType.classic
    /// Track gilt als gespielt (History), wenn er so viele Sekunden hörbar lief
    public var historyThreshold = 30.0
    /// Grid-Anker beim Laden auf Takt-/Phrasenanfang prüfen (aus / vorschlagen / automatisch verschieben)
    public var phraseAnchor = PhraseAnchorMode.suggest
    /// so viele Sekunden keine Audiodaten: Hinweis (Datei-Dienst) bzw. Abbruch (Dekodieren im Prozess)
    public var loadTimeout = 4.0
    /// Datei-Dienst: so viele Sekunden keine Audiodaten -> Helfer abschießen, Laden abbrechen (Drive antwortet nicht)
    public var loadAbortTimeout = 60.0
    /// Größe des Caches dekodierter Tracks (GB), älteste werden gelöscht
    public var cacheLimitGB = 8.0
    /// Lade-Schutz: in ein spielendes Deck wird nicht geladen (⌥-Klick, Shift + LOAD laden trotzdem)
    public var loadProtection = true
    public var activeLoopMode = ActiveLoopMode.always
    /// Auto-Loop beim Laden: so viele Takte (4 / 8 / 16 / 32), 0 = aus. Nur ohne gespeicherten Loop, nicht aktiv
    public var autoLoopBars = 16
    public init() {}
}

/// Meldung des Kerns für die Statusleiste (kommt auf beliebigem Thread)
public struct EngineNotice: Sendable, Equatable {
    public enum Level: Int, Sendable { case info, ok, warning, error }
    public var level: Level
    /// gleicher Schlüssel ersetzt die vorige Meldung an ihrer Stelle
    public var key: String
    public var text: String
    public var detail: String?
    public init(_ level: Level, key: String, _ text: String, detail: String? = nil) {
        self.level = level; self.key = key; self.text = text; self.detail = detail
    }
}

public struct DeckState: Equatable, Sendable {
    public var track: Track?
    public var duration: Double = 0
    public var loading = false
    public var error: String?
    public var grid: BeatGrid?
    /// Phrasen-Anker-Vorschlag: Ankerzeit (s), auf der die Strukturwechsel auf 8-Takt-Grenzen fallen, und Sicherheit
    public var phraseTarget: Double?
    public var phraseConfidence = 0.0
    /// Grid von Hand gesetzt (eigene Änderung, gewinnt über Collection und Analyse; RESET nimmt sie weg)
    public var gridEdited = false
    /// Schnitt (nicht destruktiv): gespielt wird nur dazwischen
    public var trim = TrackTrim()

    public var playing = false
    public var cuePoint: Double = 0
    public var cueHeld = false
    public var hotcues: [Int: Cue] = [:]
    public var reverse = false
    public var flux = false

    public var tempoPct: Double = 0
    public var tempoRange: Double = 8
    public var nudge: Double = 0
    public var bend: Double = 0
    /// Hand auf der Wellenform (Wellenform greifen): Sync hält die Phase, bis sie loslässt
    public var grab = false
    public var keylock = true
    public var keyShift = 0
    public var sync = false

    public var loopSize: Double = 4
    public var jumpSize: Double = 4
    public var loopIn: Double?
    public var loopActive = false
    /// Active Loop: Hotcues (0–7) mit Loop, die beim Erreichen ihres Anfangs von selbst einrasten (edits.json)
    public var activeLoops: Set<Int> = []
    /// der (inaktive) Loop im Kern ist der Auto-Loop vom Laden, kein Loop des Nutzers; jede Loop-Aktion nimmt das weg
    public var autoLoop = false

    public var gainDb: Double = 0
    public var eqLow: Double = 0
    public var eqMid: Double = 0
    public var eqHigh: Double = 0
    public var filter: Double = 0
    public var fader: Double = 1
    public var xf: XFAssign = .a
    public var fxAssign: [Bool] = [false, false, false, false]

    public init() {}

    public var rate: Double { (1 + tempoPct / 100) * (1 + nudge + bend) }
    /// gespielter Bereich (Schnitt, sonst die ganze Datei), Sekunden
    public var playRange: ClosedRange<Double> { trim.range(duration: duration) }
    public var bpm: Double { (grid?.bpm ?? track?.bpm ?? 0) * (1 + tempoPct / 100) }
}

public struct MixState: Equatable, Sendable {
    public var decks = (0..<MixEngine.deckCount).map { i -> DeckState in
        var d = DeckState()
        d.xf = i % 2 == 0 ? .a : .b
        // FX 1 auf A/C, FX 2 auf B/D – sonst wirken eingeschaltete Effekte auf kein Deck
        d.fxAssign = i % 2 == 0 ? [true, false, false, false] : [false, true, false, false]
        return d
    }
    public var fx = [FXUnitState(), FXUnitState(), FXUnitState(), FXUnitState()]
    public var masterDeck: Int?
    /// automatisch gewählter Master: bleibt, solange er spielt (ein neu gestartetes Deck übernimmt ihn nicht)
    public var autoMaster: Int?
    /// Master-Clock: im Clock-Modus gibt MINOS das Tempo vor (kein Deck ist Master)
    public var clockMaster = false
    /// Semi-Sync: jeder neu geladene Track übernimmt das Tempo des aktuellen Masters (kein Phasen-Sync);
    /// ein ungesynctes Deck startet in Phase zum Master (einmaliger Sprung, danach frei)
    public var semiSync = false
    public var clockBPM: Double = 128
    public var metronome = false
    public var metronomeVolume: Double = 0.5
    public var linkEnabled = false
    /// verbundene Link-Teilnehmer
    public var linkPeers = 0
    /// Link-Zeitachse neu gesetzt seit dem Einschalten (Diagnose; Tooltip der LINK-Taste)
    public var linkForces = 0
    /// Link folgen (Zwei-Mac-Modus, der andere Mac führt): Tempo und Takt der Clock kommen von Link
    public var linkFollow = false
    /// Folgen gerade aktiv (Link-Teilnehmer da; der Steuertick setzt es)
    public var linkFollowing = false
    public var crossfader: Double = 0
    public var masterVolume: Double = 0.85
    public var externalMixer = false
    public var prefs = EnginePrefs()
    /// je FX-Unit: zuweisbare Parameter des geladenen Effekts, Bedienelemente (FXControl.slot) mit Ziel und Stellung
    public var fxParams = [[FXParam]](repeating: [], count: MixEngine.fxUnitCount)
    public var fxControls = [[FXControlInfo]](repeating: Array(repeating: FXControlInfo(), count: FXControl.allCases.count),
                                              count: MixEngine.fxUnitCount)
    /// je FX-Unit und Master-Bus (Index MixController.masterBus): letzter Plugin-Ladefehler
    public var pluginErrors = [String?](repeating: nil, count: MixEngine.fxUnitCount + 1)
    /// je FX-Unit und Master-Bus: Slot rechnet (eingebaut immer, Plugin sobald geladen)
    public var slotReady = [[Bool]](repeating: [], count: MixEngine.fxUnitCount + 1)
    /// Master-Bus: Insert-Slots nach der Summe der Decks (interner Mixer)
    public var masterFX = MasterFXState()

    public init() {}

    /// Die Clock ist Takt-Master für gesyncte Decks (CLOCK-Modus oder Link-Folgen); ein Master-Deck bleibt für die Anzeige
    public var clockIsMaster: Bool { clockMaster || linkFollowing }

    /// Tempo, dem gesyncte Decks folgen (Clock oder Master-Deck)
    public var masterTempo: Double {
        if clockIsMaster { return clockBPM }
        return effectiveMaster.map { decks[$0].bpm } ?? clockBPM
    }

    public var effectiveMaster: Int? {
        if clockMaster { return nil }
        if let m = masterDeck, decks[m].grid != nil { return m }
        if let a = autoMaster, decks[a].playing, decks[a].grid != nil { return a }
        return decks.indices.first { decks[$0].playing && !decks[$0].sync && decks[$0].grid != nil }
            ?? decks.indices.first { decks[$0].playing && decks[$0].grid != nil }
    }
}

// MARK: - Steuerkern

/// Deck- und Mixlogik, unabhängig von der Oberfläche.
/// Läuft auf einer eigenen Steuer-Queue (hohe Priorität, 200 Hz): Sync-Nachführung, Controller, LEDs.
/// Oberfläche und Controller rufen nur Befehle auf; Zustand ist mit einer Sperre geschützt.
/// Der Audio-Thread nimmt die Sperre nie – er liest nur `DeckPlayer`.
public final class MixController: @unchecked Sendable {
    /// Rate aus den Audio-Einstellungen (0 = Gerät) – der Kern rechnet ab dem Start damit
    /// Messung: MIX741_CORE_RATE setzt nur die Kernrate (Gerät bleibt, AUHAL rechnet um), z. B. Live-Rate am eingebauten Gerät
    public let engine = MixEngine(rate: {
        if let r = ProcessInfo.processInfo.environment["MIX741_CORE_RATE"].flatMap(Double.init), r > 0 { return r }
        let r = E2E.defaults.double(forKey: "sampleRate"); return r > 0 ? r : nil
    }())
    public let controlQueue = DispatchQueue(label: "minos741.control", qos: .userInteractive)

    private let lock = NSRecursiveLock()
    /// Zustand des Kerns; jede Änderung zählt `revision` hoch (der Mirror holt den Schnappschuss nur dann)
    private var state = MixState() { didSet { revision &+= 1 } }
    private var revision: UInt64 = 0
    private var audio: [TrackAudio?] = Array(repeating: nil, count: MixEngine.deckCount)
    /// zählt Ladevorgänge je Deck: nur der zuletzt gestartete darf das Deck belegen
    /// (zwei Ladevorgänge kurz hintereinander enden sonst in beliebiger Reihenfolge)
    private var loadSeq = [Int](repeating: 0, count: MixEngine.deckCount)
    private var fluxReverseRestore: [Int: Bool] = [:]
    /// Active Loop je Deck: scharf (rastet beim Erreichen ein) bzw. schon benutzt (Modus „einmal je Laden“)
    private var loopArmed = [Set<Int>](repeating: [], count: MixEngine.deckCount)
    private var loopUsed = [Set<Int>](repeating: [], count: MixEngine.deckCount)
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var bigError = [Int](repeating: 0, count: MixEngine.deckCount)
    /// Fix-Sync: von Hand eingestellter Phasenversatz je Deck (Beats)
    private var phaseOffset = [Double](repeating: 0, count: MixEngine.deckCount)
    // History: hörbare Spielzeit je Deck seit dem Laden
    private var playedTime = [Double](repeating: 0, count: MixEngine.deckCount)
    private var playedLogged = [Bool](repeating: false, count: MixEngine.deckCount)
    private var playStart = [Date?](repeating: nil, count: MixEngine.deckCount)
    /// Wird (auf der Steuer-Queue) gerufen, sobald ein Track als gespielt gilt: Deck, Track, Startzeit
    public var onPlayed: ((Int, Track, Date) -> Void)?

    /// Statusmeldungen (Ladefehler, Phrasen-Vorschlag, Plugin-Fehler); beliebiger Thread
    public var onNotice: (@Sendable (EngineNotice) -> Void)?
    /// Dekoder im Prozess: URL, Rate, Fortschritt (Frames; false = abbrechen). Tests setzen einen langsamen/hängenden ein
    public var decoder: @Sendable (URL, Double, @escaping (Int) -> Bool) throws -> TrackAudio = {
        try TrackAudio.decode(url: $0, sampleRate: $1, progress: $2)
    }
    /// Datei-Dienst (eigene Prozesse); nil = im Prozess dekodieren (`decoder`, Escape-Hatch MIX741_INPROC_FILES=1)
    public var fileService: FileServiceClient? {
        didSet { applyCacheLimit() }
    }

    /// zusätzliche Aufgaben im Steuertakt (z. B. Controller-LEDs)
    private var tickHandlers: [(MixController) -> Void] = []
    /// laufende Ladevorgänge, vom Wächter im Steuertakt geprüft (unter der Sperre)
    private var loads: [PendingLoad] = []

    public init() {
        observeInvalidation()
        for u in state.fx.indices { prepareControls(u, adopt: false) }   // Standardbelegung; gemerkte kommt mit setPrefs
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: controlQueue)
        timer?.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer?.setEventHandler { [weak self] in self?.tick() }
        timer?.resume()
    }

    // MARK: Zugriff

    public func snapshot() -> MixState { locked { state } }
    /// Zähler der Zustandsänderungen; gleicher Wert = `snapshot()` unverändert (zuerst lesen, dann holen)
    public func snapshotRevision() -> UInt64 { locked { revision } }
    public func trackAudio(_ d: Int) -> TrackAudio? { locked { audio[d] } }
    public func position(_ d: Int) -> Double { engine.position(d) }
    /// hörbare Spielzeit seit dem Laden (für die History-Dauer)
    public func playedSeconds(_ d: Int) -> Double { locked { playedTime[d] } }

    /// Aufgabe, die bei jedem 6. Takt (~33 Hz) auf der Steuer-Queue läuft
    public func addTickHandler(_ h: @escaping (MixController) -> Void) { locked { tickHandlers.append(h) } }

    @discardableResult
    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    public func setPrefs(_ p: EnginePrefs) {
        locked {
            state.prefs = p
            state.prefs.fxMappings = FXMigration.mappings(p.fxMappings)   // gemerkte Gruppen-Belegungen (bis 2026-10)
            applyCacheLimit()
            engine.setMetronome(on: state.metronome, volume: state.metronomeVolume, firstChannel: p.metronomeChannel)
            applyAllMixer()
            applyAllFX()
            applyMaster()
        }
    }

    private func applyCacheLimit() {
        let gb = locked { state.prefs.cacheLimitGB }
        if let fs = fileService, fs.cacheLimit != Int64(gb * 1e9) { fs.cacheLimit = Int64(gb * 1e9) }
    }

    public func setExternalMixer(_ on: Bool) { locked { state.externalMixer = on; applyAllMixer(); applyMaster(); applyMasterFX() } }

    // MARK: Positionen / Phase

    /// tatsächlicher Phasenabstand zum Master (Anzeige)
    public func phaseError(_ d: Int) -> Double? { locked { rawPhaseError(d) } }

    /// Beat-Position, an der sich gesyncte Decks ausrichten (Clock oder Master-Deck)
    private func masterBeat() -> Double? {
        if state.clockIsMaster { return engine.clockBeat }
        guard let m = state.effectiveMaster, let mg = state.decks[m].grid else { return nil }
        return mg.beatPosition(at: position(m))
    }

    /// Phasenfehler gegenüber dem Ziel (Master-Phase plus gehaltener Versatz im Fix-Sync)
    private func phaseErrorLocked(_ d: Int) -> Double? {
        guard let e = rawPhaseError(d) else { return nil }
        var r = e - phaseOffset[d]
        r -= r.rounded()
        return r
    }

    // MARK: Laden

    /// Lade-Schutz: spielt das Deck (oder CUE gehalten), wird nicht geladen – Hinweis in der Statusleiste
    public func loadBlocked(_ d: Int) -> Bool {
        let blocked = locked { state.prefs.loadProtection && (engine.player(d).playing || state.decks[d].cueHeld) }
        if blocked {
            onNotice?(EngineNotice(.warning, key: "loadlock.\(d)", String(localized: "Deck \(Self.deckLetter(d)) spielt · Laden gesperrt")))
        }
        return blocked
    }

    /// `trim` / `gridEdited` / `activeLoops`: eigene Änderungen des Tracks (Schnitt, von Hand gesetztes Grid, Active Loops)
    public func load(_ t: Track, deck d: Int, trim: TrackTrim = TrackTrim(), gridEdited: Bool = false, activeLoops: Set<Int> = []) {
        let rate = engine.sampleRate
        let (seq, timeout): (Int, Double) = locked {
            loadSeq[d] += 1
            state.decks[d].loading = true
            state.decks[d].error = nil
            state.decks[d].playing = false
            engine.player(d).playing = false
            return (loadSeq[d], max(0.5, state.prefs.loadTimeout))
        }
        let watch = LoadWatch()
        let service = fileService.flatMap { $0.unavailable ? nil : $0 }
        locked { loads.append(PendingLoad(deck: d, seq: seq, track: t, watch: watch, timeout: timeout, service: service != nil)) }
        if let service {
            loadViaService(service, t, d, seq: seq, rate: rate, watch: watch, trim: trim, gridEdited: gridEdited, activeLoops: activeLoops)
            return
        }
        loadInProcess(t, d, seq: seq, rate: rate, watch: watch, trim: trim, gridEdited: gridEdited, activeLoops: activeLoops)
    }

    /// Dekodieren im eigenen Prozess (heutiger Weg): ein hängendes Lesen lässt sich nicht abbrechen, nur verwerfen
    private func loadInProcess(_ t: Track, _ d: Int, seq: Int, rate: Double, watch: LoadWatch, trim: TrackTrim, gridEdited: Bool, activeLoops: Set<Int>) {
        let decode = decoder
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Datei-Prüfung nicht auf dem aufrufenden (Haupt-)Thread: in einem Cloud-Ordner kann schon der Blick
            // ins Verzeichnis auf den Anbieter warten. Hängt sie, bricht der Wächter nach der Zeitgrenze ab
            guard FileManager.default.fileExists(atPath: t.path) else {
                watch.progress(Int.max)
                failLoad(t, d, seq: seq, reason: String(localized: "Datei fehlt"), timeout: nil,
                         text: String(localized: "Datei fehlt: \(Self.displayName(t))"))
                return
            }
            let dataless = CloudRead.isDataless(t.path)
            do {
                let t0 = Date()
                let a = try decode(URL(fileURLWithPath: t.path), rate) { [self] frames in
                    watch.progress(frames)
                    return !watch.cancelled && locked { seq == loadSeq[d] }
                }
                if Self.debug {
                    print(String(format: "[load] deck %d: %.2f s, %.0f MB", d, Date().timeIntervalSince(t0), Double(a.frames) * 8 / 1e6))
                }
                watch.progress(Int.max)
                finishLoad(t, a, d, seq: seq, trim: trim, gridEdited: gridEdited, activeLoops: activeLoops)
            } catch TrackAudio.DecodeError.cancelled {
                // abgebrochen: Zeitüberschreitung (schon gemeldet) oder ein anderer Track gewählt
            } catch {
                watch.progress(Int.max)
                let cloud = CloudRead.notLocal(path: t.path, datalessBefore: dataless, datalessAfter: CloudRead.isDataless(t.path))
                failLoad(t, d, seq: seq, reason: cloud ? Self.notLocalReason : Self.reason(error), timeout: nil)
            }
        }
    }

    /// Dekodieren im Datei-Dienst: dieser Prozess berührt den Musikpfad nicht. Hängt die Datei, schießt der Client den
    /// Helfer nach `loadAbortTimeout` ohne Daten ab; ein anderer Track für das Deck schießt ihn sofort ab
    private func loadViaService(_ fs: FileServiceClient, _ t: Track, _ d: Int, seq: Int, rate: Double, watch: LoadWatch,
                                trim: TrackTrim, gridEdited: Bool, activeLoops: Set<Int>) {
        let hard = locked { max(5, state.prefs.loadAbortTimeout) }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let t0 = Date()
            do {
                let a = try fs.decode(path: t.path, sampleRate: rate, hardTimeout: hard, progress: { stage, frames in
                    watch.progress(frames, fetching: stage == .fetching)
                }, cancelled: { watch.cancelled || self.locked { seq != self.loadSeq[d] } })
                if Self.debug {
                    print(String(format: "[load] deck %d: %.2f s, %.0f MB (file service)", d, Date().timeIntervalSince(t0), Double(a.frames) * 8 / 1e6))
                }
                watch.progress(Int.max)
                finishLoad(t, a, d, seq: seq, trim: trim, gridEdited: gridEdited, activeLoops: activeLoops)
            } catch FileServiceClient.ServiceError.cancelled {
                // anderer Track gewählt: Helfer schon abgeschossen
            } catch FileServiceClient.ServiceError.unavailable {
                // Helfer startet nicht: dieses Mal im Prozess (alter Weg, mit seiner Zeitgrenze)
                onNotice?(EngineNotice(.warning, key: "files", String(localized: "Datei-Dienst startet nicht – Tracks werden im Programm dekodiert")))
                locked { if let i = loads.firstIndex(where: { $0.deck == d && $0.seq == seq }) { loads[i].service = false } }
                loadInProcess(t, d, seq: seq, rate: rate, watch: watch, trim: trim, gridEdited: gridEdited, activeLoops: activeLoops)
            } catch FileServiceClient.ServiceError.missing {
                watch.progress(Int.max)
                failLoad(t, d, seq: seq, reason: String(localized: "Datei fehlt"), timeout: nil,
                         text: String(localized: "Datei fehlt: \(Self.displayName(t))"))
            } catch let FileServiceClient.ServiceError.stalled(s) {
                watch.progress(Int.max)
                failLoad(t, d, seq: seq, reason: String(localized: "keine Audiodaten (Drive antwortet nicht)"), timeout: s)
            } catch {
                watch.progress(Int.max)
                failLoad(t, d, seq: seq, reason: Self.reason(error), timeout: nil)
            }
        }
    }

    /// Fortschritt eines Ladevorgangs (Dekoder-Thread schreibt, Wächter liest)
    private final class LoadWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var last = DispatchTime.now()
        private var done = false
        private var stop = false
        private var cloud = false
        var cancelled: Bool { lock.withLock { stop } }
        /// Datei liegt nur online, der Anbieter lädt sie
        var fetching: Bool { lock.withLock { cloud } }
        /// Frames gelesen; Int.max = Lesen fertig (danach rechnet nur noch die Analyse)
        func progress(_ frames: Int, fetching: Bool = false) {
            lock.withLock { last = .now(); if frames == .max { done = true }; if fetching { cloud = true } }
        }
        /// Sekunden ohne neue Daten (nil = fertig gelesen)
        func stalled() -> Double? {
            lock.withLock { done ? nil : Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1e9 }
        }
        func cancel() { lock.withLock { stop = true } }
    }

    private struct PendingLoad {
        let deck: Int, seq: Int, track: Track, watch: LoadWatch, timeout: Double
        /// über den Datei-Dienst: nach `timeout` nur ein Hinweis, abgebrochen wird im Client
        var service: Bool
        var warned = false
    }

    /// Wächter (Steuertakt, alle 0,25 s): kommen `timeout` Sekunden keine Audiodaten, wird der Ladevorgang abgebrochen
    /// (das Ergebnis verworfen) – bzw. im Datei-Dienst nur gemeldet. Läuft im Steuertakt und nicht auf einer
    /// Hintergrund-Queue: unter CPU-Last (Analyse, Builds) kommt eine Utility-Queue Sekunden zu spät, ein hängender
    /// Dekoder belegte dann doch noch das Deck. Liefert abgelaufene und langsame Ladevorgänge; melden außerhalb der Sperre
    private func expiredLoads() -> (expired: [PendingLoad], slow: [PendingLoad]) {
        var expired: [PendingLoad] = [], slow: [PendingLoad] = []
        loads.removeAll { l in
            guard l.seq == loadSeq[l.deck], let idle = l.watch.stalled() else { return true }   // überholt oder fertig gelesen
            guard idle >= l.timeout else { return false }
            if l.service { return false }
            l.watch.cancel()
            expired.append(l)
            return true
        }
        for i in loads.indices where loads[i].service && !loads[i].warned {
            guard let idle = loads[i].watch.stalled(), idle >= loads[i].timeout else { continue }
            loads[i].warned = true
            slow.append(loads[i])
        }
        return (expired, slow)
    }

    /// Laden fehlgeschlagen: Deck leer, Fehler am Deck, Meldung in der Statusleiste. Gilt nur für den aktuellen Ladevorgang
    private func failLoad(_ t: Track, _ d: Int, seq: Int, reason: String, timeout: Double?, text: String? = nil) {
        let r: (TrackAudio?, UInt32)? = locked {
            guard seq == loadSeq[d] else { return nil }
            loadSeq[d] += 1   // ein später fertiger Dekoder darf das Deck nicht mehr belegen
            return emptyDeck(d, error: String(localized: "Nicht ladbar: \(reason)"))
        }
        guard let (old, gen) = r else { return }
        releaseWhenFree(old, deck: d, gen: gen)
        let name = Self.displayName(t)
        let text = text ?? timeout.map { String(localized: "Track nicht ladbar (\(Int($0.rounded())) s): \(name) · \(reason)") }
            ?? String(localized: "Track nicht ladbar: \(name) · \(reason)")
        onNotice?(EngineNotice(.error, key: "load.\(d)", text, detail: t.path))
        if Self.debug { print("[load] deck \(d): \(text)"); fflush(stdout) }
    }

    /// Deck leeren (unter der Sperre): Track, Grid, Cues, Loop, Schnitt weg; liefert den alten Puffer zum Freigeben
    private func emptyDeck(_ d: Int, error: String?) -> (TrackAudio?, UInt32) {
        let old = audio[d]
        audio[d] = nil
        var s = state.decks[d]
        s.track = nil; s.grid = nil; s.duration = 0; s.hotcues = [:]; s.cuePoint = 0
        s.phraseTarget = nil; s.loopActive = false; s.loopIn = nil; s.activeLoops = []; s.reverse = false; s.flux = false
        s.autoLoop = false
        s.loading = false; s.playing = false; s.trim = TrackTrim(); s.gridEdited = false
        s.error = error
        state.decks[d] = s
        playedTime[d] = 0; playedLogged[d] = false; playStart[d] = nil
        engine.setLoop(d, active: false, start: 0, end: 0)
        engine.setTrim(d, start: 0, end: 0)
        return (old, engine.attach(nil, deck: d, startAt: 0))
    }

    /// Auswerfen: Deck leer (auch ein laufendes Laden oder eine Fehlermeldung), nur wenn es nicht spielt
    @discardableResult
    public func eject(_ d: Int) -> Bool {
        guard (0..<MixEngine.deckCount).contains(d) else { return false }
        let r: (TrackAudio?, UInt32)? = locked {
            let s = state.decks[d]
            guard !engine.player(d).playing, !s.cueHeld, s.track != nil || s.loading || s.error != nil else { return nil }
            loadSeq[d] += 1   // laufendes Laden verwerfen
            return emptyDeck(d, error: nil)
        }
        guard let (old, gen) = r else { return false }
        releaseWhenFree(old, deck: d, gen: gen)
        return true
    }

    static func displayName(_ t: Track) -> String {
        let a = t.artist.trimmingCharacters(in: .whitespaces), ti = t.title.trimmingCharacters(in: .whitespaces)
        if a.isEmpty && ti.isEmpty { return URL(fileURLWithPath: t.path).lastPathComponent }
        return a.isEmpty ? ti : (ti.isEmpty ? a : "\(a) – \(ti)")
    }

    private static func reason(_ e: Error) -> String {
        if case TrackAudio.DecodeError.format = e { return String(localized: "Format nicht lesbar") }
        if case let TrackAudio.DecodeError.convert(m) = e { return String(localized: "Umwandlung: \(m)") }
        if let s = e as? FileServiceClient.ServiceError {
            switch s {
            case let .failed(code, detail):
                switch code {
                case .format: return String(localized: "Format nicht lesbar")
                case .convert: return String(localized: "Umwandlung: \(detail)")
                case .cacheWrite: return String(localized: "Cache nicht beschreibbar: \(detail)")
                case .notLocal: return notLocalReason
                default: return detail
                }
            case .crashed: return String(localized: "Datei-Dienst abgestürzt")
            case .unresponsive: return String(localized: "Datei-Dienst antwortet nicht")
            case let .invalid(m): return String(localized: "Antwort des Datei-Dienstes ungültig: \(m)")
            default: break
            }
        }
        let ns = e as NSError
        return ns.localizedFailureReason ?? ns.localizedDescription
    }

    static let notLocalReason = String(localized: "Datei nicht lokal verfügbar (Cloud)")

    static func deckLetter(_ d: Int) -> String { ["A", "B", "C", "D"][max(0, min(3, d))] }

    /// MIX741_DEBUG=1: Lade-, Hänger- und Controller-Protokoll
    public static let debug = ProcessInfo.processInfo.environment["MIX741_DEBUG"] == "1"

    private func finishLoad(_ t: Track, _ a: TrackAudio, _ d: Int, seq: Int, trim: TrackTrim, gridEdited: Bool, activeLoops: Set<Int>) {
        let r: (TrackAudio?, UInt32)? = locked {
            guard seq == loadSeq[d] else { return nil }   // überholt: ein später gewählter Track lädt noch oder liegt schon
            let old = audio[d]
            var s = state.decks[d]
            let p = state.prefs
            s.track = t
            s.grid = BeatGrid(track: t)
            s.gridEdited = gridEdited && s.grid != nil
            s.phraseTarget = nil
            s.duration = a.duration
            s.trim = trim.normalized(duration: a.duration) ?? TrackTrim()
            s.hotcues = Dictionary(t.hotcues.map { ($0.hotcue, $0) }, uniquingKeysWith: { x, _ in x })
            let loadCue = (t.cues.first { $0.kind == .load }?.startMs ?? t.gridAnchorMs ?? 0) / 1000
            s.cuePoint = switch p.loadPosition {
                case .loadCue: loadCue
                case .start: 0
                case .firstHotcue: (s.hotcues[0]?.startMs ?? loadCue * 1000) / 1000
            }
            // Cue im Schnitt (Ladeposition, CUE, CUP): davor oder dahinter -> Schnitt-Anfang
            if !s.playRange.contains(s.cuePoint) { s.cuePoint = s.playRange.lowerBound }
            s.loopActive = false
            s.loopIn = nil
            s.activeLoops = activeLoops.filter { s.hotcues[$0].map(Self.isLoop) ?? false }
            s.autoLoop = false
            s.reverse = false
            s.keyShift = 0
            s.loading = false
            s.playing = false
            if old == nil {   // erster Track im Deck: Standardwerte aus den Einstellungen
                s.keylock = p.keylockDefault
                s.tempoRange = p.tempoRangeDefault
                s.loopSize = p.defaultLoopSize
                s.jumpSize = p.defaultJumpSize
            }
            if state.semiSync, t.bpm > 0, state.clockIsMaster || state.effectiveMaster != nil {
                // Semi-Sync: Tempo des aktuellen Masters übernehmen (ohne Phasen-Sync); halbes/doppeltes Tempo wählt
                // das nächste Verhältnis; der Tempo-Bereich wächst bei Bedarf auf die nächste Stufe
                var ratio = state.masterTempo / t.bpm
                while ratio > 1.5 { ratio /= 2 }
                while ratio < 0.75 { ratio *= 2 }
                let pct = (ratio - 1) * 100
                if abs(pct) > s.tempoRange, let r = [6.0, 8, 10, 16, 50, 100].first(where: { $0 >= abs(pct) }) { s.tempoRange = r }
                s.tempoPct = max(-s.tempoRange, min(s.tempoRange, pct))
            }
            state.decks[d] = s
            audio[d] = a
            playedTime[d] = 0
            playedLogged[d] = false
            playStart[d] = nil
            loopUsed[d] = []
            armLoops(d, at: s.cuePoint)
            engine.setTrim(d, start: s.trim.start ?? 0, end: s.trim.end ?? 0)   // vor dem Puffer: der erste Block kennt ihn schon
            let gen = engine.attach(a, deck: d, startAt: s.cuePoint)
            if !placeAutoLoop(d) { engine.setLoop(d, active: false, start: 0, end: 0) }   // kein Loop vom vorigen Track
            applyRate(d)
            applyMixer(d)
            applyAllFX()
            return (old, gen)
        }
        guard let (old, gen) = r else { return }   // `a` wird hier freigegeben, der Kern hat es nie gesehen
        releaseWhenFree(old, deck: d, gen: gen)
        onNotice?(EngineNotice(.info, key: "load.\(d)", String(localized: "Deck \(Self.deckLetter(d)): \(Self.displayName(t))")))
        analyzePhrase(d, a)
    }

    /// Phrasen-Anker im Hintergrund prüfen; gilt nur, solange derselbe Track mit demselben Grid im Deck liegt
    private func analyzePhrase(_ d: Int, _ a: TrackAudio) {
        guard let (mode, grid) = locked({ () -> (PhraseAnchorMode, BeatGrid)? in
            guard state.prefs.phraseAnchor != .off, let g = state.decks[d].grid, g.bpm > 0 else { return nil }
            return (state.prefs.phraseAnchor, g)
        }) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let r = PhraseAnchor.analyze(a, grid: grid)
            guard r.suggests else { return }
            let applied: Bool = locked {
                guard audio[d] === a, state.decks[d].grid == grid else { return false }
                if mode == .auto {
                    state.decks[d].grid?.anchor += Double(r.shiftBeats) * grid.beat
                    state.decks[d].gridEdited = true   // eigene Änderung (edits.json), RESET nimmt sie weg
                } else {
                    state.decks[d].phraseTarget = grid.anchor + Double(r.shiftBeats) * grid.beat
                    state.decks[d].phraseConfidence = r.confidence
                }
                if state.decks[d].autoLoop, !state.decks[d].loopActive { placeAutoLoop(d) }   // auf den Phrasen-Anker
                return true
            }
            if applied {
                let shift = String(format: "%+d", r.shiftBeats)
                onNotice?(EngineNotice(.info, key: "phrase.\(d)", mode == .auto
                    ? String(localized: "Deck \(Self.deckLetter(d)): Grid-Anker auf Phrasenanfang verschoben (\(shift) Beats)")
                    : String(localized: "Deck \(Self.deckLetter(d)): Phrasen-Anker vorgeschlagen (\(shift) Beats)")))
            }
            if applied, ProcessInfo.processInfo.environment["MIX741_DEBUG"] == "1" {
                print(String(format: "[phrase] deck %d: %@ %+d beats (conf %.2f)", d, mode == .auto ? "anchor" : "suggest",
                             r.shiftBeats, r.confidence))
                fflush(stdout)
            }
        }
    }

    /// Instant Double: Track von Deck `s` in Deck `d` – dieselben Audiodaten (kein Laden), dieselbe Position (im Kern
    /// sample-genau zu `s`), Tempo, Keylock, Key-Shift, Sync, Loop, Cues, Grid, Schnitt. Spielt `s`, läuft `d` mit.
    /// Mixer und FX von `d` bleiben. Lade-Schutz gilt (`force` übergeht ihn)
    @discardableResult
    public func instantDouble(from s: Int, to d: Int, force: Bool = false) -> Bool {
        guard s != d, (0..<MixEngine.deckCount).contains(s), (0..<MixEngine.deckCount).contains(d) else { return false }
        if !force, loadBlocked(d) { return false }
        let r: (TrackAudio?, UInt32, Track)? = locked {
            guard let a = audio[s], let t = state.decks[s].track, !state.decks[s].loading else { return nil }
            loadSeq[d] += 1   // laufendes Laden in `d` verwerfen
            let old = audio[d], src = state.decks[s], playing = engine.player(s).playing
            var n = state.decks[d]
            n.track = t; n.grid = src.grid; n.gridEdited = src.gridEdited
            n.phraseTarget = src.phraseTarget; n.phraseConfidence = src.phraseConfidence
            n.duration = src.duration; n.trim = src.trim; n.hotcues = src.hotcues; n.cuePoint = src.cuePoint
            n.loading = false; n.error = nil
            n.tempoPct = src.tempoPct; n.tempoRange = src.tempoRange; n.nudge = 0; n.bend = 0
            n.keylock = src.keylock; n.keyShift = src.keyShift; n.sync = src.sync
            n.loopSize = src.loopSize; n.jumpSize = src.jumpSize; n.loopIn = src.loopIn; n.loopActive = src.loopActive
            n.activeLoops = src.activeLoops; n.autoLoop = src.autoLoop
            n.reverse = false; n.flux = false; n.cueHeld = false; n.playing = playing
            state.decks[d] = n
            audio[d] = a
            playedTime[d] = 0; playedLogged[d] = true; playStart[d] = nil   // derselbe Track: kein zweiter History-Eintrag
            phaseOffset[d] = phaseOffset[s]; bigError[d] = 0
            loopArmed[d] = loopArmed[s]; loopUsed[d] = loopUsed[s]
            engine.player(d).flux = false
            engine.setTrim(d, start: n.trim.start ?? 0, end: n.trim.end ?? 0)
            let gen = engine.attach(a, deck: d, startAt: position(s))
            let l = engine.loop(s)
            engine.setLoop(d, active: l.active, start: l.start, end: l.end)
            engine.follow(d, deck: s)
            applyRate(d)
            applyMixer(d)
            applyAllFX()
            engine.player(d).playing = playing   // nach attach (stoppt das Deck): startet im selben Block wie die Übernahme
            applyRate(d)
            return (old, gen, t)
        }
        guard let (old, gen, t) = r else { return false }
        releaseWhenFree(old, deck: d, gen: gen)
        onNotice?(EngineNotice(.info, key: "load.\(d)",
                               String(localized: "Deck \(Self.deckLetter(d)): Double von \(Self.deckLetter(s)) · \(Self.displayName(t))")))
        return true
    }

    /// EDIT-Modus: anderes Audio für den geladenen Track ohne Laden (gerenderte Schnittliste bzw. zurück zum Original).
    /// Grid, Hotcues aus `t`, Cue-Punkt, Schnitt und Active Loops wie übergeben; Tempo, Keylock, Key-Shift, Sync, Mixer
    /// bleiben, ein Loop geht aus. Ein spielendes Deck läuft an `position` weiter. false = Deck leer oder lädt gerade
    @discardableResult
    public func swapAudio(_ d: Int, track t: Track, audio a: TrackAudio, position: Double, cuePoint: Double,
                          gridEdited: Bool = false, trim: TrackTrim = TrackTrim(), activeLoops: Set<Int> = []) -> Bool {
        guard (0..<MixEngine.deckCount).contains(d) else { return false }
        let r: (TrackAudio?, UInt32)? = locked {
            guard audio[d] != nil, !state.decks[d].loading else { return nil }
            loadSeq[d] += 1   // ein später fertiger Ladevorgang darf das Deck nicht mehr belegen
            let old = audio[d], playing = engine.player(d).playing, keepAuto = state.decks[d].autoLoop
            var s = state.decks[d]
            s.track = t
            s.grid = BeatGrid(track: t)
            s.gridEdited = gridEdited && s.grid != nil
            s.phraseTarget = nil
            s.duration = a.duration
            s.trim = trim.normalized(duration: a.duration) ?? TrackTrim()
            s.hotcues = Dictionary(t.hotcues.map { ($0.hotcue, $0) }, uniquingKeysWith: { x, _ in x })
            s.cuePoint = min(max(0, cuePoint), a.duration)
            if !s.playRange.contains(s.cuePoint) { s.cuePoint = s.playRange.lowerBound }
            s.loopActive = false
            s.loopIn = nil
            s.activeLoops = activeLoops.filter { s.hotcues[$0].map(Self.isLoop) ?? false }
            s.autoLoop = false
            s.reverse = false
            s.flux = false
            s.playing = playing
            state.decks[d] = s
            audio[d] = a
            loopUsed[d] = []
            let at = min(max(0, position), a.duration)
            armLoops(d, at: at)
            engine.player(d).flux = false
            engine.setTrim(d, start: s.trim.start ?? 0, end: s.trim.end ?? 0)
            let gen = engine.attach(a, deck: d, startAt: at)
            if !(keepAuto && placeAutoLoop(d)) { engine.setLoop(d, active: false, start: 0, end: 0) }   // Auto-Loop bleibt
            applyRate(d)
            engine.player(d).playing = playing   // attach stoppt das Deck: im selben Block weiter
            applyRate(d)
            return (old, gen)
        }
        guard let (old, gen) = r else { return false }
        releaseWhenFree(old, deck: d, gen: gen)
        return true
    }

    /// alten Puffer halten, bis der Audio-Thread den neuen übernommen hat – ohne Zeitlimit
    /// (steht die Ausgabe, liest ihn niemand; hängt sie, bleibt lieber ein Puffer liegen als dass sie in freien Speicher greift)
    private func releaseWhenFree(_ old: TrackAudio?, deck d: Int, gen: UInt32) {
        guard let old else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            if engine.trackConsumed(d, gen) || !engine.running { _ = old; return }
            releaseWhenFree(old, deck: d, gen: gen)
        }
    }

    // MARK: Transport

    public func togglePlay(_ d: Int) {
        locked {
            guard audio[d] != nil else { return }
            let p = engine.player(d)
            if p.playing { p.playing = false } else {
                if state.decks[d].sync { alignPhase(d, hard: true) } else { semiAlignStart(d) }
                p.playing = true
            }
            state.decks[d].cueHeld = false
            state.decks[d].playing = p.playing
            applyRate(d)
        }
    }

    public func cueDown(_ d: Int) {
        locked {
            guard audio[d] != nil else { return }
            let p = engine.player(d)
            if p.playing {
                p.playing = false
                jump(d, to: state.decks[d].cuePoint, "cue")
            } else if abs(position(d) - state.decks[d].cuePoint) < 0.02 {
                semiAlignStart(d)   // Cue-Vorhören startet ebenfalls in Phase; CUE loslassen springt zurück zum Cue
                p.playing = true
                state.decks[d].cueHeld = true
            } else {
                state.decks[d].cuePoint = snapped(d, position(d))
                jump(d, to: state.decks[d].cuePoint, "cue set")
            }
            state.decks[d].playing = p.playing
            applyRate(d)
        }
    }

    public func cueUp(_ d: Int) {
        locked {
            guard state.decks[d].cueHeld else { return }
            engine.player(d).playing = false
            jump(d, to: state.decks[d].cuePoint, "cue release")
            state.decks[d].cueHeld = false
            state.decks[d].playing = false
            applyRate(d)
        }
    }

    public func cup(_ d: Int) {
        locked {
            guard audio[d] != nil else { return }
            jump(d, to: state.decks[d].cuePoint, "cup")
            semiAlignStart(d)   // vom Cue aus in Phase zum Master starten
            engine.player(d).playing = true
            state.decks[d].playing = true
            applyRate(d)
        }
    }

    public func seek(_ d: Int, fraction: Double) {
        locked { seek(d, seconds: max(0, min(1, fraction)) * state.decks[d].duration) }
    }

    /// Von Hand verschoben (Wellenform ziehen, Touchstrip): im Fix-Sync bleibt die neue Phase
    public func seek(_ d: Int, seconds: Double) {
        locked {
            jump(d, to: seconds, "seek")
            if state.prefs.syncMode == .fixed, state.decks[d].sync, let g = state.decks[d].grid, let mb = masterBeat() {
                phaseOffset[d] = BeatGrid.phaseError(own: g.beatPosition(at: seconds), master: mb)
                bigError[d] = 0
            }
        }
    }

    public func setReverse(_ d: Int, _ on: Bool) {
        locked {
            state.decks[d].reverse = on
            engine.player(d).reverse = on
            if !on, state.decks[d].flux { jump(d, to: engine.fluxPosition(d), "flux return") }
        }
    }

    public func toggleReverse(_ d: Int) { locked { setReverse(d, !state.decks[d].reverse) } }

    public func toggleFlux(_ d: Int) {
        locked {
            state.decks[d].flux.toggle()
            engine.player(d).flux = state.decks[d].flux
        }
    }

    /// Flux Reverse: gehalten rückwärts, beim Loslassen an der Stelle weiter, an der der Track ohne Reverse wäre.
    public func fluxReverse(_ d: Int, on: Bool) {
        locked {
            guard audio[d] != nil else { return }
            let p = engine.player(d)
            if on {
                fluxReverseRestore[d] = state.decks[d].flux
                state.decks[d].flux = true; p.flux = true
                state.decks[d].reverse = true; p.reverse = true
            } else {
                state.decks[d].reverse = false; p.reverse = false
                jump(d, to: engine.fluxPosition(d), "flux reverse return")
                let r = fluxReverseRestore[d] ?? false
                state.decks[d].flux = r; p.flux = r
                fluxReverseRestore[d] = nil
            }
        }
    }

    // MARK: Hotcues

    public func hotcue(_ d: Int, _ n: Int, delete: Bool = false) {
        locked {
            guard audio[d] != nil else { return }
            if delete { state.decks[d].hotcues[n] = nil; state.decks[d].activeLoops.remove(n); return }
            if let c = state.decks[d].hotcues[n] {
                var target = c.startMs / 1000
                if state.prefs.quantize, state.prefs.hotcueKeepsPhase, state.decks[d].playing, let g = state.decks[d].grid {
                    target += position(d) - g.beatFloor(position(d))
                }
                jump(d, to: target, "hotcue \(n + 1)")
                if c.kind == .loop, c.lengthMs > 0 { loopOn(d, start: c.startMs / 1000, end: (c.startMs + c.lengthMs) / 1000) }
            } else if state.decks[d].loopActive {
                state.decks[d].activeLoops.remove(n)
                let l = engine.loop(d)
                state.decks[d].hotcues[n] = Cue(name: "Loop", kind: .loop, startMs: l.start * 1000,
                                                lengthMs: (l.end - l.start) * 1000, hotcue: n)
            } else {
                state.decks[d].activeLoops.remove(n)
                state.decks[d].hotcues[n] = Cue(name: "Cue", kind: .cue, startMs: snapped(d, position(d)) * 1000,
                                                lengthMs: 0, hotcue: n)
            }
        }
    }

    // MARK: Loops / Beatjump

    private func beatLength(_ d: Int) -> Double { state.decks[d].grid?.beat ?? 0.5 }

    /// Zeit in den gespielten Bereich (Schnitt); ohne Track unverändert
    private func inRange(_ d: Int, _ t: Double) -> Double {
        guard state.decks[d].duration > 0 else { return max(0, t) }
        let r = state.decks[d].playRange
        return min(max(t, r.lowerBound), r.upperBound)
    }

    /// Sprungziel, das die Beat-Phase hält: um ganze Beats in den gespielten Bereich
    private func inRangeKeepingPhase(_ d: Int, _ t: Double, beat: Double) -> Double {
        guard beat > 0, state.decks[d].duration > 0 else { return inRange(d, t) }
        let r = state.decks[d].playRange
        var t = t
        if t < r.lowerBound { t += ((r.lowerBound - t) / beat).rounded(.up) * beat }
        if t > r.upperBound { t -= (((t - r.upperBound) / beat).rounded(.down) + 1) * beat }   // vor dem Ende, nicht darauf
        return inRange(d, t)
    }

    /// Loop einschalten, auf den gespielten Bereich gekürzt; false = kein Platz (Loop bleibt, wie er war)
    @discardableResult
    private func loopOn(_ d: Int, start: Double, end: Double) -> Bool {
        var s = start, e = end
        if state.decks[d].duration > 0 {
            let r = state.decks[d].playRange
            s = max(s, r.lowerBound); e = min(e, r.upperBound)
        }
        guard e > s + 0.01 else { return false }
        engine.setLoop(d, active: true, start: s, end: e)
        state.decks[d].loopActive = true
        state.decks[d].autoLoop = false
        return true
    }

    /// jeder Sprung des Kerns läuft hier durch; MIX741_DEBUG=1: `[jump] deck A: von → nach (Grund)`
    private func jump(_ d: Int, to target: Double, _ reason: @autoclosure () -> String) {
        let from = Self.debug ? position(d) : 0
        let t = inRange(d, target)
        engine.seek(d, seconds: t)
        guard Self.debug else { return }
        let deck = String(UnicodeScalar(UInt8(65 + d)))
        let beats = state.decks[d].grid.map { String(format: ", %+.2f beats", (max(0, t) - from) / $0.beat) } ?? ""
        print(String(format: "[jump] deck %@: %.3f → %.3f s (%@%@)", deck, from, max(0, t), reason(), beats))
        fflush(stdout)
    }

    /// Snap: Cue-/Loop-Punkte auf den nächsten Beat
    private func snapped(_ d: Int, _ t: Double) -> Double {
        guard state.prefs.snap, let g = state.decks[d].grid else { return t }
        return g.nearestBeat(to: t)
    }

    /// Beats je Snap-Phrase: 4 Takte, gezählt ab dem Grid-Anker
    private static let snapPhraseBeats = 16.0

    /// Loop-Snap: gespeicherter Loop-Cue (Hotcue oder Memory-Cue), der kurz vor der Position beginnt
    /// oder gerade überspielt wird (Position noch im Loop). Der nächstgelegene gewinnt.
    private func nearbyLoopCue(_ d: Int) -> (start: Double, end: Double)? {
        let p = state.prefs
        guard p.snap, p.loopSnapCues, !state.decks[d].reverse, let g = state.decks[d].grid else { return nil }
        let pos = position(d), w = p.loopSnapCueBeats * g.beat
        let memory = state.decks[d].track?.cues.filter { $0.hotcue < 0 } ?? []
        return (Array(state.decks[d].hotcues.values) + memory)
            .filter { $0.kind == .loop && $0.lengthMs > 0 }
            .map { (start: $0.startMs / 1000, end: ($0.startMs + $0.lengthMs) / 1000) }
            .filter { $0.start <= pos + w && $0.start >= pos - w && pos < $0.end }
            .min { abs($0.start - pos) < abs($1.start - pos) }
    }

    /// Loop-Snap: 4-Takt-Grenze (ab dem Grid-Anker) innerhalb der Toleranz um die Position
    private func nearbyPhraseStart(_ d: Int) -> Double? {
        let p = state.prefs
        guard p.snap, p.loopSnapPhrase, !state.decks[d].reverse, let g = state.decks[d].grid else { return nil }
        let b = g.beatPosition(at: position(d))
        let n = (b / Self.snapPhraseBeats).rounded() * Self.snapPhraseBeats
        guard abs(b - n) <= p.loopSnapPhraseBeats + 1e-9 else { return nil }
        return g.time(ofBeat: n)
    }

    /// Loop-Cue als Loop übernehmen, ohne Sprung (die Position läuft hinein bzw. ist schon drin)
    private func activateLoopCue(_ d: Int, _ c: (start: Double, end: Double)) {
        guard loopOn(d, start: c.start, end: c.end) else { return }
        let beats = (c.end - c.start) / beatLength(d)
        if let s = BeatSizes.loop.first(where: { abs($0 - beats) < 0.01 }) { state.decks[d].loopSize = s }
    }

    // MARK: Auto-Loop beim Laden

    /// Lage des Auto-Loops: erster voller Phrasenbeginn (8 Takte ab Phrasen-Anker, sonst Grid-Anker) an oder nach dem Anfang
    /// des gespielten Bereichs, `bars` Takte lang, ganz im Bereich. nil = kein Grid oder kein Platz
    public static func autoLoopRange(grid: BeatGrid?, phraseAnchor: Double? = nil, bars: Int,
                                     range: ClosedRange<Double>) -> (start: Double, end: Double)? {
        guard bars > 0, let g = grid, g.bpm > 0, g.bpm.isFinite else { return nil }
        let base = BeatGrid(anchor: phraseAnchor ?? g.anchor, bpm: g.bpm)
        let phrase = Double(PhraseAnchor.phraseBeats)
        let n = ((base.beatPosition(at: range.lowerBound) - 1e-6) / phrase).rounded(.up) * phrase
        let start = base.time(ofBeat: n), end = base.time(ofBeat: n + Double(bars * 4))
        guard start >= range.lowerBound - 1e-6, end <= range.upperBound + 1e-6 else { return nil }
        return (start, end)
    }

    /// gespeicherter Loop im Deck: Loop-Hotcue (Collection oder edits.json) oder Loop-Memory-Cue
    private func hasStoredLoop(_ d: Int) -> Bool {
        state.decks[d].hotcues.values.contains(where: Self.isLoop)
            || (state.decks[d].track?.cues.contains { $0.hotcue < 0 && Self.isLoop($0) } ?? false)
    }

    /// Auto-Loop (nicht aktiv) in den Kern, wenn eingestellt, Grid da und kein gespeicherter Loop; unter der Sperre
    @discardableResult
    private func placeAutoLoop(_ d: Int) -> Bool {
        let s = state.decks[d]
        guard !s.loopActive, s.duration > 0, !hasStoredLoop(d),
              let r = Self.autoLoopRange(grid: s.grid, phraseAnchor: s.phraseTarget, bars: state.prefs.autoLoopBars, range: s.playRange)
        else {
            if s.autoLoop { engine.setLoop(d, active: false, start: 0, end: 0) }   // passt nach dem Phrasen-Anker nicht mehr
            state.decks[d].autoLoop = false
            return false
        }
        engine.setLoop(d, active: false, start: r.start, end: r.end)
        state.decks[d].autoLoop = true
        return true
    }

    /// LOOP mit gesetztem Auto-Loop: die Position liegt darin oder bis zum Loop-Snap-Fenster davor -> dieser Loop, kein Sprung
    private func autoLoopAhead(_ d: Int) -> (start: Double, end: Double)? {
        guard state.decks[d].autoLoop, !state.decks[d].loopActive, !state.decks[d].reverse else { return nil }
        let l = engine.loop(d), pos = position(d), w = state.prefs.loopSnapCueBeats * beatLength(d)
        return pos >= l.start - w && pos < l.end ? (l.start, l.end) : nil
    }

    // MARK: Active Loop

    /// so weit vor dem Loop-Anfang (s Track, × Tempo) wird eingeschaltet: der Kern springt erst am Loop-Ende zurück,
    /// davor läuft die Position normal hinein – sample-genau, ohne dass der Steuertakt den Anfang genau treffen muss
    private static let activeLoopLead = 0.05
    /// so weit hinter dem Anfang rastet er noch ein (Steuertakt verspätet); weiter drin = hineingesprungen, nicht erreicht
    private static let activeLoopGrace = 0.25

    static func isLoop(_ c: Cue) -> Bool { c.kind == .loop && c.lengthMs > 0 }

    /// Hotcue `n` als Active Loop an/aus (nur Loop-Cues)
    public func toggleActiveLoop(_ d: Int, _ n: Int) {
        locked {
            guard let c = state.decks[d].hotcues[n], Self.isLoop(c) else { return }
            if state.decks[d].activeLoops.remove(n) == nil {
                state.decks[d].activeLoops.insert(n)
                loopUsed[d].remove(n)
                if position(d) < c.startMs / 1000 + Self.activeLoopGrace { loopArmed[d].insert(n) }
            } else {
                loopArmed[d].remove(n)
            }
        }
    }

    /// nach dem Laden: Active Loops, deren Anfang noch vor (oder an) der Position liegt, sind scharf
    private func armLoops(_ d: Int, at t: Double) {
        loopArmed[d] = state.decks[d].activeLoops.filter { n in
            state.decks[d].hotcues[n].map { t < $0.startMs / 1000 + Self.activeLoopGrace } ?? false
        }
    }

    /// Steuertakt: erreicht die Position (vorwärts, kein anderer Loop an) den Anfang eines scharfen Active Loops, rastet
    /// er ein. Danach erst wieder scharf, wenn die Position vor dem Anfang liegt (Loop-Taste verlässt ihn, der nächste
    /// Durchlauf greift wieder) – im Modus „einmal je Laden“ nicht mehr
    private func checkActiveLoops(_ d: Int) {
        guard !state.decks[d].activeLoops.isEmpty, audio[d] != nil else { return }   // vor der Kopie: Normalfall 200 Hz × 4
        let s = state.decks[d]
        let pos = position(d), lead = Self.activeLoopLead * max(1, s.rate)
        for n in s.activeLoops {
            guard let c = s.hotcues[n], Self.isLoop(c) else { continue }
            let start = c.startMs / 1000, end = (c.startMs + c.lengthMs) / 1000
            if pos < start - lead {
                if !loopUsed[d].contains(n) { loopArmed[d].insert(n) }
                continue
            }
            guard loopArmed[d].contains(n) else { continue }
            if pos >= min(end, start + Self.activeLoopGrace) { loopArmed[d].remove(n); continue }   // darüber gesprungen
            guard s.playing, !s.reverse, !s.loopActive else { continue }
            loopArmed[d].remove(n)
            if state.prefs.activeLoopMode == .once { loopUsed[d].insert(n) }
            activateLoopCue(d, (start, end))
            if Self.debug { print(String(format: "[loop] deck %@: active loop %d at %.3f s (%.3f–%.3f)", Self.deckLetter(d), n + 1, pos, start, end)); fflush(stdout) }
        }
    }

    public func autoLoop(_ d: Int, size: Double? = nil) {
        locked {
            guard audio[d] != nil else { return }
            let s = size ?? state.decks[d].loopSize
            if state.decks[d].loopActive, size == nil || s == state.decks[d].loopSize { exitLoop(d); return }
            if size == nil, let c = autoLoopAhead(d) { activateLoopCue(d, c); return }
            if !state.decks[d].loopActive, let c = nearbyLoopCue(d) { activateLoopCue(d, c); return }
            state.decks[d].loopSize = s
            let pos = position(d)
            // 4-Takt-Grenze: Loop beginnt dort, die Position läuft hinein oder ist schon drin (sonst normaler Snap)
            if !state.decks[d].loopActive, let start = nearbyPhraseStart(d), pos < start + s * beatLength(d),
               loopOn(d, start: start, end: start + s * beatLength(d)) {
                return
            }
            var start = state.decks[d].loopActive ? engine.loop(d).start : pos
            if !state.decks[d].loopActive, state.prefs.quantize, let g = state.decks[d].grid {
                let unit = min(1, s)
                start = g.time(ofBeat: (g.beatPosition(at: pos) / unit).rounded(.down) * unit)
            }
            loopOn(d, start: start, end: start + s * beatLength(d))   // am Schnitt-Ende gekürzt
        }
    }

    public func exitLoop(_ d: Int) {
        locked {
            let l = engine.loop(d)
            engine.setLoop(d, active: false, start: l.start, end: l.end)
            state.decks[d].loopActive = false
            if state.decks[d].flux { jump(d, to: engine.fluxPosition(d), "flux return") }
        }
    }

    public func reloop(_ d: Int) {
        locked {
            let l = engine.loop(d)
            guard l.end > l.start else { return }
            if state.decks[d].loopActive { exitLoop(d); return }
            let auto = state.decks[d].autoLoop
            guard loopOn(d, start: l.start, end: l.end) else { return }
            let r = engine.loop(d)
            if auto, let s = BeatSizes.loop.first(where: { abs($0 - (r.end - r.start) / beatLength(d)) < 0.01 }) { state.decks[d].loopSize = s }
            if position(d) > r.end || position(d) < r.start { jump(d, to: r.start, "reloop") }
        }
    }

    public func changeLoopSize(_ d: Int, by step: Int) {
        locked {
            let sizes = BeatSizes.loop
            let i = sizes.firstIndex(of: state.decks[d].loopSize) ?? 7
            state.decks[d].loopSize = sizes[max(0, min(sizes.count - 1, i + step))]
            if state.decks[d].loopActive {
                let l = engine.loop(d)
                loopOn(d, start: l.start, end: l.start + state.decks[d].loopSize * beatLength(d))
            }
        }
    }

    public func setLoopSize(_ d: Int, _ s: Double) { locked { state.decks[d].loopSize = s } }

    /// Loop auf einen Bereich (Markierung in der Wellenform), auf den Schnitt gekürzt; liegt die Position außerhalb,
    /// springt sie an den Anfang. false = kein Track oder kein Platz
    @discardableResult
    public func setLoop(_ d: Int, start: Double, end: Double) -> Bool {
        locked {
            guard audio[d] != nil, loopOn(d, start: start, end: end) else { return false }
            let l = engine.loop(d)
            let beats = (l.end - l.start) / beatLength(d)
            if let s = BeatSizes.loop.first(where: { abs($0 - beats) < 0.01 }) { state.decks[d].loopSize = s }
            if position(d) > l.end || position(d) < l.start { jump(d, to: l.start, "loop from range") }
            return true
        }
    }

    public func setLoopIn(_ d: Int) {
        locked {
            if !state.decks[d].loopActive, let c = nearbyLoopCue(d) {
                state.decks[d].loopIn = c.start
                activateLoopCue(d, c)
                return
            }
            state.decks[d].loopIn = nearbyPhraseStart(d) ?? snapped(d, position(d))
        }
    }

    public func setLoopOut(_ d: Int) {
        locked {
            guard let a = state.decks[d].loopIn else { return }
            let b = snapped(d, position(d))
            guard b > a + 0.01, loopOn(d, start: a, end: b) else { return }
            jump(d, to: engine.loop(d).start, "loop out")
        }
    }

    /// Beatjump; bei aktivem Loop springt er um die Loop-Länge (in Richtung des Sprungs) und nimmt den Loop mit:
    /// die Stelle im Loop bleibt dieselbe, der Sprung ist nicht zu hören
    public func beatjump(_ d: Int, beats: Double) {
        locked {
            guard audio[d] != nil else { return }
            let beats = state.decks[d].loopActive ? (beats < 0 ? -state.decks[d].loopSize : state.decks[d].loopSize) : beats
            let delta = beats * beatLength(d)
            if state.decks[d].loopActive {
                // Loop wandert mit; passt er nicht mehr in den Schnitt, bleibt alles stehen
                let l = engine.loop(d), r = state.decks[d].playRange
                guard l.start + delta >= r.lowerBound - 1e-6, l.end + delta <= r.upperBound + 1e-6 else { return }
                engine.setLoop(d, active: true, start: l.start + delta, end: l.end + delta)
            }
            // über den Schnitt hinaus: um ganze Beats zurück hinein (Phase bleibt)
            jump(d, to: inRangeKeepingPhase(d, position(d) + delta, beat: beatLength(d)), String(format: "beatjump %+g", beats))
        }
    }

    /// genau einen Takt springen; im Loop bleibt der Loop stehen und die Position läuft darin um
    /// (so landen beide Tracks auf derselben Takt-Eins im 4/4)
    public func barJump(_ d: Int, bars: Int) { stepJump(d, beats: bars * 4, reason: "bar jump \(bars > 0 ? "+" : "")\(bars)") }

    /// um ganze Beats springen (Controller: Sync + Pad 3/4 = ein Beat); im Loop bleibt der Loop stehen
    /// und die Position läuft darin um
    public func stepJump(_ d: Int, beats: Int, reason: String? = nil) {
        locked {
            guard audio[d] != nil else { return }
            var t = position(d) + Double(beats) * beatLength(d)
            if state.decks[d].loopActive {
                let l = engine.loop(d)
                let len = l.end - l.start
                if len > 0 { t = l.start + (t - l.start).truncatingRemainder(dividingBy: len); if t < l.start { t += len } }
            }
            jump(d, to: max(0, t), reason ?? "step \(beats > 0 ? "+" : "")\(beats)")
        }
    }

    public func changeJumpSize(_ d: Int, by step: Int) {
        locked {
            let sizes = BeatSizes.jump
            let i = sizes.firstIndex(of: state.decks[d].jumpSize) ?? 4
            state.decks[d].jumpSize = sizes[max(0, min(sizes.count - 1, i + step))]
        }
    }

    public func setJumpSize(_ d: Int, _ s: Double) { locked { state.decks[d].jumpSize = s } }

    // MARK: Tempo / Sync

    public func setTempo(_ d: Int, _ pct: Double) { locked { state.decks[d].tempoPct = pct; applyRate(d) } }
    public func setTempoRange(_ d: Int, _ r: Double) { locked { state.decks[d].tempoRange = r } }

    public func toggleSync(_ d: Int) {
        locked {
            state.decks[d].sync.toggle()
            if state.decks[d].sync { alignPhase(d, hard: state.decks[d].playing) }
            else { state.decks[d].nudge = 0; applyRate(d) }
        }
    }

    public func toggleMaster(_ d: Int) {
        locked {
            state.masterDeck = state.masterDeck == d ? nil : d
            state.decks[d].nudge = 0
            applyRate(d)
        }
    }

    public func toggleKeylock(_ d: Int) { locked { state.decks[d].keylock.toggle(); applyRate(d) } }

    public func shiftKey(_ d: Int, _ step: Int) {
        locked {
            state.decks[d].keyShift = step == 0 ? 0 : max(-12, min(12, state.decks[d].keyShift + step))
            applyRate(d)
        }
    }

    /// Key Sync: Key-Shift so, dass der hörbare Key zum hörbaren Key des Master-Decks passt (gleich oder Nachbar auf dem
    /// Open-Key-Rad, kleinster Betrag, höchstens ±6). Keylock aus -> an. Ergebnis als Hinweis in der Statusleiste
    public func keySync(_ d: Int) {
        let notice: EngineNotice = locked {
            let deck = Self.deckLetter(d), key = "keysync.\(d)"
            guard let t = state.decks[d].track, t.musicalKey >= 0 else {
                return EngineNotice(.warning, key: key, String(localized: "Deck \(deck): Key Sync ohne Key des Tracks"))
            }
            guard let m = state.effectiveMaster, m != d, let mt = state.decks[m].track, mt.musicalKey >= 0 else {
                return EngineNotice(.warning, key: key, String(localized: "Deck \(deck): Key Sync braucht ein anderes Master-Deck mit Key"))
            }
            let ms = state.decks[m]
            // hörbare Abweichung des Masters: Key-Shift, ohne Keylock zusätzlich das Tempo (wie die Key-Anzeige)
            let dev = Double(ms.keyShift) + (ms.keylock ? 0 : 12 * log2(max(1 + ms.tempoPct / 100, 1e-6)))
            let mShift = Int(dev.rounded())
            let s = KeySync.shift(code: t.musicalKey, masterCode: mt.musicalKey, masterShift: mShift, current: state.decks[d].keyShift)
            let keylockOn = !state.decks[d].keylock
            state.decks[d].keylock = true
            state.decks[d].keyShift = s
            applyRate(d)
            let own = t.openKey(shiftedBy: s), master = mt.openKey(shiftedBy: mShift), shift = String(format: "%+d", s)
            return keylockOn
                ? EngineNotice(.info, key: key, String(localized: "Deck \(deck): Keylock an, Key-Shift \(shift) -> \(own) (Master \(master))"))
                : EngineNotice(.info, key: key, String(localized: "Deck \(deck): Key-Shift \(shift) -> \(own) (Master \(master))"))
        }
        onNotice?(notice)
    }

    /// Wellenform greifen (Vinyl): die Hand läuft dem Ziel (Sekunden) nach; `held` false = losgelassen. Im Fix-Sync hält
    /// das Loslassen die erreichte Phase, wie ein Sprung von Hand
    public func scratch(_ d: Int, to seconds: Double, held: Bool) {
        locked {
            guard audio[d] != nil else { return }
            let was = state.decks[d].grab
            state.decks[d].grab = held
            engine.scratch(d, seconds: seconds, held: held)
            if !held, was, state.prefs.syncMode == .fixed, state.decks[d].sync, let g = state.decks[d].grid, let mb = masterBeat() {
                phaseOffset[d] = BeatGrid.phaseError(own: g.beatPosition(at: seconds), master: mb)
                bigError[d] = 0
            }
        }
    }

    /// Wellenform greifen (Jog): Hand auf dem Teller oder losgelassen; solange sie drauf ist, zieht der Sync nicht nach
    public func grab(_ d: Int, _ on: Bool) { locked { state.decks[d].grab = on } }

    /// Pitch-Bend: −1…1 × eingestellte Stärke
    public func bend(_ d: Int, _ v: Double) {
        locked {
            let was = state.decks[d].bend
            state.decks[d].bend = v * state.prefs.bendAmount
            // Bend losgelassen: im Fix-Sync die erreichte Phase halten, sonst zurück auf 0
            if v == 0, was != 0 {
                phaseOffset[d] = state.prefs.syncMode == .fixed ? (rawPhaseError(d) ?? 0) : 0
                bigError[d] = 0
            }
            applyRate(d)
        }
    }

    /// Phasenfehler ohne gehaltenen Versatz
    private func rawPhaseError(_ d: Int) -> Double? {
        if !state.clockIsMaster, state.effectiveMaster == d { return nil }
        guard let g = state.decks[d].grid, let mb = masterBeat() else { return nil }
        return BeatGrid.phaseError(own: g.beatPosition(at: position(d)), master: mb)
    }

    private func alignPhase(_ d: Int, hard: Bool) {
        guard let g = state.decks[d].grid, g.bpm > 0 else { return }
        if !state.clockIsMaster { guard let m = state.effectiveMaster, m != d else { return } }
        state.decks[d].tempoPct = (state.masterTempo / g.bpm - 1) * 100
        state.decks[d].nudge = 0
        phaseOffset[d] = 0
        applyRate(d)
        if hard, let e = phaseErrorLocked(d) {
            jump(d, to: inRangeKeepingPhase(d, position(d) - e * g.beat, beat: g.beat), "sync align")
        }
    }

    /// Semi-Sync-Start: ein ungesynctes Deck springt beim Start einmalig auf den nächsten Beat des laufenden Masters
    /// (Fehler −0,5…0,5 Beats) und läuft dann frei – Tempo, Nudge und Sync-Zustand bleiben unverändert.
    /// Nichts passiert ohne laufenden Master oder wenn das Deck selbst Master ist.
    private func semiAlignStart(_ d: Int) {
        guard state.semiSync, !state.decks[d].sync, let g = state.decks[d].grid, g.bpm > 0 else { return }
        if !state.clockIsMaster { guard let m = state.effectiveMaster, m != d, state.decks[m].playing else { return } }
        guard let e = rawPhaseError(d) else { return }
        // vor dem Trackanfang / Schnitt-Start: einen Beat später
        jump(d, to: inRangeKeepingPhase(d, position(d) - e * g.beat, beat: g.beat), "semi start")
    }

    // MARK: Beatgrid bearbeiten
    // jede Änderung ist eine eigene (gridEdited): sie gewinnt über Collection und Analyse, bis RESET

    /// Grid verschieben (ms, + = später)
    public func shiftGrid(_ d: Int, ms: Double) {
        locked {
            guard var g = state.decks[d].grid else { return }
            g.anchor += ms / 1000
            state.decks[d].grid = g
            state.decks[d].gridEdited = true
        }
    }

    /// BPM des Grids ändern (Anker bleibt)
    public func setGridBPM(_ d: Int, _ bpm: Double) {
        locked {
            guard var g = state.decks[d].grid, bpm > 20, bpm < 400 else { return }
            g.bpm = bpm
            state.decks[d].grid = g
            state.decks[d].gridEdited = true
            applyRate(d)
        }
    }

    public func scaleGridBPM(_ d: Int, _ f: Double) { locked { if let g = state.decks[d].grid { setGridBPM(d, g.bpm * f) } } }

    /// Grid-Marker an die aktuelle Position (Beat 1 hier)
    public func setGridAnchorHere(_ d: Int) {
        locked {
            let pos = position(d)
            if var g = state.decks[d].grid {
                g.anchor = pos
                state.decks[d].grid = g
            } else if let t = state.decks[d].track, t.bpm > 0 {
                state.decks[d].grid = BeatGrid(anchor: pos, bpm: t.bpm)
            } else { return }
            state.decks[d].gridEdited = true
        }
    }

    /// Anker um ganze Beats verschieben (+ = später): Raster und BPM bleiben, nur die Takt-/Phrasenzählung wandert
    public func shiftGridBeats(_ d: Int, _ n: Int) {
        locked {
            guard var g = state.decks[d].grid, g.bpm > 0 else { return }
            g.anchor += Double(n) * g.beat
            state.decks[d].grid = g
            state.decks[d].gridEdited = true
        }
    }

    /// Phrasen-Anker-Vorschlag übernehmen
    public func applyPhraseAnchor(_ d: Int) {
        locked {
            guard let n = state.decks[d].phraseSuggestion else { return }
            shiftGridBeats(d, n)
        }
    }

    /// Grid auf den Wert der Library (Collection bzw. eigene Analyse) zurücksetzen: eigene Änderung weg
    public func resetGrid(_ d: Int, original: Track) {
        locked {
            state.decks[d].grid = BeatGrid(track: original)
            state.decks[d].gridEdited = false
            applyRate(d)
        }
    }

    private var gridTaps: [Int: [Double]] = [:]
    /// Tap auf die Beats: ab 4 Taps BPM des Grids aus dem mittleren Abstand (Pause > 2 s beginnt neu). Ohne Grid
    /// entsteht eines mit Beat 1 an der Position des letzten Taps. Anker bleibt sonst
    public func tapGrid(_ d: Int, at time: Double = ProcessInfo.processInfo.systemUptime) {
        locked {
            guard audio[d] != nil else { return }
            var taps = gridTaps[d] ?? []
            if let last = taps.last, time - last > 2 || time < last { taps.removeAll() }
            taps.append(time)
            if taps.count > 16 { taps.removeFirst() }
            gridTaps[d] = taps
            guard taps.count >= 4, let first = taps.first, let last = taps.last, last > first else { return }
            let bpm = 60 / ((last - first) / Double(taps.count - 1))
            guard bpm > 40, bpm < 300 else { return }
            let rounded = (bpm * 100).rounded() / 100
            if var g = state.decks[d].grid { g.bpm = rounded; state.decks[d].grid = g }
            else { state.decks[d].grid = BeatGrid(anchor: position(d), bpm: rounded) }
            state.decks[d].gridEdited = true
            applyRate(d)
        }
    }

    /// neue Analyse des geladenen Tracks übernehmen: BPM, Key, Lautheit, Grid-Anker; ein von Hand geändertes Grid bleibt
    public func applyAnalysis(_ d: Int, track t: Track) {
        locked {
            guard var cur = state.decks[d].track, cur.key == t.key else { return }
            cur.bpm = t.bpm; cur.musicalKey = t.musicalKey; cur.keyText = t.keyText
            cur.perceivedDb = t.perceivedDb; cur.peakDb = t.peakDb; cur.ownAnalysis = t.ownAnalysis
            cur.cues.removeAll { $0.kind == .grid }
            cur.cues += t.cues.filter { $0.kind == .grid }
            state.decks[d].track = cur
            if !state.decks[d].gridEdited { state.decks[d].grid = BeatGrid(track: cur) }
            applyRate(d)
            applyMixer(d)
        }
    }

    /// ganzes Grid setzen (übernommen, z. B. aus Warp-Markern der DAW): eigene Änderung wie jede Grid-Bearbeitung
    public func setGrid(_ d: Int, _ g: BeatGrid) {
        locked {
            guard state.decks[d].track != nil, g.bpm > 20, g.bpm < 1000, g.anchor.isFinite else { return }
            state.decks[d].grid = g
            state.decks[d].gridEdited = true
            applyRate(d)
        }
    }

    // MARK: Schnitt (nicht destruktiv)

    /// Schnitt setzen (Sekunden, nil = Anfang / Ende der Datei). Zu kurz (< 1 s) oder ohne Track: nichts, false.
    /// Cue-Punkt und Loop rücken in den Schnitt, die Position springt bei Bedarf hinein (Kern)
    @discardableResult
    public func setTrim(_ d: Int, _ trim: TrackTrim) -> Bool {
        locked {
            guard audio[d] != nil, state.decks[d].duration > 0,
                  let t = trim.normalized(duration: state.decks[d].duration) else { return false }
            state.decks[d].trim = t
            engine.setTrim(d, start: t.start ?? 0, end: t.end ?? 0)
            let r = state.decks[d].playRange
            if !r.contains(state.decks[d].cuePoint) { state.decks[d].cuePoint = r.lowerBound }
            if state.decks[d].loopActive {
                let l = engine.loop(d)
                if l.start < r.lowerBound || l.end > r.upperBound, !loopOn(d, start: l.start, end: l.end) {
                    engine.setLoop(d, active: false, start: l.start, end: l.end)
                    state.decks[d].loopActive = false
                }
            }
            return true
        }
    }

    /// Schnitt-Anfang bzw. -Ende an die Position (Quantize: auf den nächsten Beat, `free` = genau hier)
    @discardableResult
    public func trimHere(_ d: Int, end: Bool, free: Bool = false) -> Bool {
        locked {
            var t = position(d)
            if !free, state.prefs.quantize, let g = state.decks[d].grid, g.bpm > 0 { t = g.nearestBeat(to: t) }
            return setTrimPoint(d, end: end, t)
        }
    }

    /// einen Rand des Schnitts setzen (Ziehen in Wellenform und Übersicht)
    @discardableResult
    public func setTrimPoint(_ d: Int, end: Bool, _ t: Double) -> Bool {
        locked {
            var trim = state.decks[d].trim
            if end { trim.end = t } else { trim.start = t }
            return setTrim(d, trim)
        }
    }

    public func clearTrim(_ d: Int) { locked { _ = setTrim(d, TrackTrim()) } }

    // MARK: Rückgängig (Bearbeitungsstand eines Decks)

    /// Bearbeitungsstand eines Decks (kleine Kopie unter der Sperre, kein Audio)
    public func deckEdit(_ d: Int) -> DeckEdit {
        locked {
            let s = state.decks[d], l = engine.loop(d)
            var e = DeckEdit()
            e.trackKey = s.track?.key
            e.hotcues = s.hotcues; e.activeLoops = s.activeLoops
            e.grid = s.grid; e.gridEdited = s.gridEdited
            e.trim = s.trim; e.cuePoint = s.cuePoint
            e.loopActive = s.loopActive; e.loopStart = l.start; e.loopEnd = l.end; e.loopIn = s.loopIn; e.loopSize = s.loopSize
            e.autoLoop = s.autoLoop
            e.keyShift = s.keyShift; e.keylock = s.keylock
            e.tempoPct = s.tempoPct; e.sync = s.sync; e.masterDeck = state.masterDeck
            e.flux = s.flux
            e.position = position(d)
            return e
        }
    }

    /// Teile eines gesicherten Stands zurückschreiben (nur gleicher Track). `changedFrom` = Stand, von dem aus zurückgeschrieben
    /// wird: Hotcues nur die dazwischen geänderten (spätere Änderungen anderer Hotcues, z. B. vom Controller, bleiben).
    /// `position` = Sprungziel (s), nil = Position bleibt. Schnitt vor Loop (der Schnitt kürzt den Loop), Position zuletzt
    public func restoreDeckEdit(_ d: Int, _ e: DeckEdit, _ p: DeckEdit.Parts, changedFrom o: DeckEdit? = nil, position target: Double? = nil) {
        locked {
            guard e.trackKey != nil, state.decks[d].track?.key == e.trackKey else { return }
            if p.contains(.trim) {
                _ = setTrim(d, e.trim)
                if state.decks[d].playRange.contains(e.cuePoint) { state.decks[d].cuePoint = e.cuePoint }
            }
            if p.contains(.cues) {
                if let o {
                    for n in Set(e.hotcues.keys).union(o.hotcues.keys) where e.hotcues[n] != o.hotcues[n] { state.decks[d].hotcues[n] = e.hotcues[n] }
                    for n in e.activeLoops.symmetricDifference(o.activeLoops) {
                        if e.activeLoops.contains(n) { state.decks[d].activeLoops.insert(n) } else { state.decks[d].activeLoops.remove(n) }
                    }
                } else {
                    state.decks[d].hotcues = e.hotcues
                    state.decks[d].activeLoops = e.activeLoops
                }
                armLoops(d, at: position(d))
            }
            if p.contains(.grid) {
                state.decks[d].grid = e.grid
                state.decks[d].gridEdited = e.gridEdited
            }
            if p.contains(.loop) {
                let was = state.decks[d].loopActive
                if !(e.loopActive && e.loopEnd > e.loopStart && loopOn(d, start: e.loopStart, end: e.loopEnd)) {
                    engine.setLoop(d, active: false, start: e.loopStart, end: e.loopEnd)
                    state.decks[d].loopActive = false
                }
                state.decks[d].loopIn = e.loopIn
                state.decks[d].loopSize = e.loopSize
                state.decks[d].autoLoop = e.autoLoop && !state.decks[d].loopActive
                if was, !state.decks[d].loopActive, state.decks[d].flux, target == nil { jump(d, to: engine.fluxPosition(d), "undo loop, flux return") }
            }
            if p.contains(.key) { state.decks[d].keyShift = e.keyShift; state.decks[d].keylock = e.keylock }
            if p.contains(.sync), state.decks[d].sync != e.sync { toggleSync(d) }
            if p.contains(.master), state.masterDeck != e.masterDeck {
                state.masterDeck = e.masterDeck
                state.decks[d].nudge = 0
            }
            if p.contains(.tempo) { state.decks[d].tempoPct = e.tempoPct }
            if p.contains(.flux) { state.decks[d].flux = e.flux; engine.player(d).flux = e.flux }
            if !p.isDisjoint(with: [.grid, .key, .tempo, .master]) { applyRate(d) }
            if p.contains(.position), let target { seek(d, seconds: target) }
        }
    }

    // MARK: Master-Clock

    /// Semi-Sync: neue Tracks laden mit dem Tempo des Masters (kein Phasen-Sync), ein ungesynctes Deck startet in Phase
    public func setSemiSync(_ on: Bool) { locked { state.semiSync = on } }

    /// Clock als Master an/aus. Beim Einschalten übernimmt sie Tempo und Phase des bisherigen Masters (kein Sprung).
    public func setClockMaster(_ on: Bool) {
        locked {
            if on, !state.clockMaster, let m = state.effectiveMaster, let g = state.decks[m].grid {
                state.clockBPM = state.decks[m].bpm
                engine.setClockBPM(state.clockBPM)
                jumpClock(to: g.beatPosition(at: position(m)))
            }
            state.clockMaster = on
            if on { state.masterDeck = nil }
        }
    }

    public func setClockBPM(_ bpm: Double) {
        locked {
            state.clockBPM = max(40, min(250, (bpm * 100).rounded() / 100))
            engine.setClockBPM(state.clockBPM)
        }
    }

    public func nudgeClock(_ delta: Double) { locked { setClockBPM(state.clockBPM + delta) } }

    private var taps: [Date] = []
    /// Tap-Tempo: Mittel der letzten Abstände (Pause > 2 s beginnt neu)
    public func tap() {
        locked {
            let now = Date()
            if let last = taps.last, now.timeIntervalSince(last) > 2 { taps.removeAll() }
            taps.append(now)
            if taps.count > 8 { taps.removeFirst() }
            guard taps.count >= 3 else { return }
            let span = taps.last!.timeIntervalSince(taps.first!) / Double(taps.count - 1)
            if span > 0 {
                setClockBPM(60 / span)
                if !state.clockMaster { state.clockMaster = true; state.masterDeck = nil }
                jumpClock(to: 0)
            }
        }
    }

    public func setMetronome(_ on: Bool, volume: Double? = nil) {
        locked {
            state.metronome = on
            if let v = volume { state.metronomeVolume = v }
            engine.setMetronome(on: on, volume: state.metronomeVolume, firstChannel: state.prefs.metronomeChannel)
        }
    }

    public func setLinkEnabled(_ on: Bool) { locked { state.linkEnabled = on; link.enabled = on } }
    /// Link folgen (Zwei-Mac-Modus, der andere Mac führt Link): Tempo und Takt kommen von Link, nicht von MINOS
    public func setLinkFollow(_ on: Bool) { locked { state.linkFollow = on } }
    /// Phasenabstand der Clock zu Link in Beats und Teilnehmer (Messung; auf der Steuer-Queue wie `lead`)
    public func linkPhase() -> (error: Double, peers: Int)? {
        controlQueue.sync {
            guard let st = engine.clockStamp, let e = link.phaseError(beat: st.beat, hostTime: st.hostTime) else { return nil }
            return (e, link.peers)
        }
    }

    /// Link-Diagnose (Zähler, letzte Abweichung, Drift, Teilnehmer); `resetWindow` beginnt Max/σ neu
    public func linkStats(resetWindow: Bool = false) -> LinkStats {
        controlQueue.sync {
            locked { () -> LinkStats in
                if resetWindow { return link.takeStats() }
                var r = link.stats; r.peers = link.peers
                return r
            }
        }
    }

    /// Link – MINOS gibt Tempo und Takt vor
    public let link = LinkSession()
    private var linkTicks = 0
    /// Link folgen beim letzten Steuertick (Wechsel setzt die Nachführung neu)
    private var linkWasFollowing = false
    /// Takt-Versatz der Clock zum Master-Deck: Zähler gleicher Werte (Ticks à 5 ms) und letzter Wert
    private var clockBarTicks = 0, clockBarLast = 0.0

    // MARK: Bar-Zähler (läuft ab dem ersten Play durch, bleibt beim Master-Wechsel auf dem Beat)

    private var sessionOffset: Double?

    /// Tempo der Master-Clock (folgt im AUTO-Modus dem Master-Deck)
    public var clockTempo: Double { locked { state.clockBPM } }

    /// Beats seit dem ersten Play (nil = noch nichts gespielt)
    public var sessionBeat: Double? { locked { sessionOffset.map { engine.clockBeat + $0 } } }

    /// Zähler neu auf Takt 1 setzen (am nächsten Beat)
    public func resetSession() { locked { sessionOffset = -engine.clockBeat.rounded() } }

    /// Clock-Beat springt (Master-Wechsel, Tap) – der Zähler läuft ohne Sprung weiter, im Beat des neuen Masters
    private func jumpClock(to v: Double) {
        if let o = sessionOffset { sessionOffset = o + (engine.clockBeat - v).rounded() }
        engine.setClockBeat(v)
    }

    /// gespeicherte Sitzung übernehmen (Mixer, FX, Clock)
    public func restore(_ f: (inout MixState) -> Void) {
        locked {
            f(&state)
            for d in state.decks.indices { applyRate(d) }
            applyAllMixer(); applyAllFX(); applyMasterFX()
            engine.setClockBPM(state.clockBPM)
            engine.setMetronome(on: state.metronome, volume: state.metronomeVolume, firstChannel: state.prefs.metronomeChannel)
            applyMaster()
            link.enabled = state.linkEnabled
        }
    }

    /// Tempo an die Engine; steht das Deck, laufen Time-Stretch/Varispeed im Bypass (spart viel CPU im Leerlauf)
    private func applyRate(_ d: Int) {
        let s = state.decks[d]
        engine.setRate(d, rate: s.rate, keylock: s.keylock, keyShift: Double(s.keyShift), idle: !engine.player(d).playing)
    }

    // MARK: Mixer

    public func updateDeck(_ d: Int, _ f: (inout DeckState) -> Void) {
        locked { f(&state.decks[d]); applyMixer(d); applyAllFX() }
    }

    public func setCrossfader(_ v: Double) { locked { state.crossfader = v; applyAllMixer() } }

    public func setMasterVolume(_ v: Double) { locked { state.masterVolume = v; applyMaster() } }

    private func applyMaster() {
        let ext = state.externalMixer && !state.prefs.masterVolumeExternal
        engine.setMasterVolume(ext ? 1 : state.masterVolume)
    }

    private func applyMixer(_ d: Int) {
        let s = state.decks[d], p = state.prefs
        let ext = state.externalMixer
        // PERCEIVED_DB is the gain that brings the track to reference level (quiet track -> positive): add it
        let auto = (ext ? p.autoGainExternal : p.autoGain) ? (s.track?.perceivedDb ?? 0) : 0
        engine.setGain(d, db: s.gainDb + auto + (ext ? p.headroomExternal : p.headroomInternal))
        engine.setChannelFilter(d, s.filter, resonance: p.channelFilterResonance)
        // Extern: EQ nur mit eigener Einstellung, sonst macht das Pult den EQ
        let eqOn = !ext || p.eqExternal
        engine.setEQ(d, low: eqOn ? s.eqLow : 0, mid: eqOn ? s.eqMid : 0, high: eqOn ? s.eqHigh : 0, kill: p.eqKill)
        if ext {
            engine.setChannelVolume(d, 1)
            return
        }
        let x = state.crossfader
        let side: Double = switch s.xf {
            case .a: x <= 0 ? 1 : 1 - x
            case .b: x >= 0 ? 1 : 1 + x
            case .thru: 1
        }
        let xfGain = p.crossfaderCurve == .sharp ? (side > 0.02 ? 1 : 0) : max(0, side)
        engine.setChannelVolume(d, s.fader * s.fader * xfGain)
    }

    private func applyAllMixer() { for d in state.decks.indices { applyMixer(d) } }

    /// Ist das Deck gerade hörbar? (Extern: immer – das Pult entscheidet)
    private func audible(_ d: Int) -> Bool {
        if state.externalMixer { return true }
        let s = state.decks[d], x = state.crossfader
        let side: Double = switch s.xf {
            case .a: x <= 0 ? 1 : 1 - x
            case .b: x >= 0 ? 1 : 1 + x
            case .thru: 1
        }
        return s.fader * side > 0.05
    }

    // MARK: FX

    public func updateFX(_ u: Int, _ f: (inout FXUnitState) -> Void) {
        locked { changeFX(u, f) }
    }

    /// Änderung an einer Unit übernehmen (unter der Sperre); Slot-Regeln (Anzahl, eingebaute je einmal) gelten
    private func changeFX(_ u: Int, _ f: (inout FXUnitState) -> Void) {
        f(&state.fx[u])
        state.fx[u].slots = FXRules.valid(state.fx[u].slots)
        applyFX(u)
    }

    public func toggleFXAssign(_ d: Int, _ u: Int) {
        locked { state.decks[d].fxAssign[u].toggle(); applyFX(u) }
    }

    private func applyFX(_ u: Int) {
        syncRack(u)
        prepareControls(u)
        var fx = state.fx[u]
        // D/W der Unit wirkt nur, wenn ein Bedienelement darauf liegt (sonst voll nass, z. B. D/W auf dem Mix des Plugins)
        if !state.fxControls[u].contains(where: { $0.param?.id == "dw" }) { fx.dryWet = 1 }
        fx = liveBypassed(u, fx)
        for d in state.decks.indices { applyCoreFX(unit: u, deck: d, fx, assigned: state.decks[d].fxAssign[u]) }
    }

    /// Slots einer Unit (bzw. des Master-Busses) mit den Einstellungen an den Kern
    private func applyCoreFX(unit u: Int, deck d: Int, _ fx: FXUnitState, assigned: Bool) {
        let p = state.prefs
        engine.applyFX(unit: u, deck: d, fx, assigned: assigned, bpm: state.masterTempo > 0 ? state.masterTempo : 125,
                       feedback: p.delayFeedback, filterResonance: p.fxFilterResonance,
                       reverbLevel: pow(10, p.reverbLevelDb / 20), reverbBrightness: p.reverbBrightness,
                       reverbPreDelay: p.reverbPreDelayMs / 1000, reverbFDN: p.reverbType == .fdn)
    }

    private func applyAllFX() { for u in state.fx.indices { applyFX(u) } }

    /// Mode-Taste am Controller: Slots aus (gemerkt, welche an waren) bzw. wieder an; mit Shift die nächste Vorlage
    /// (Gruppe FLT·DLY·REV, dann je eingebauter Effekt ein Slot). Eine Vorlage übernimmt an/aus der Unit
    public func fxModeButton(_ u: Int, shift: Bool) {
        locked {
            if shift {
                let next = ((FXTemplate.index(of: state.fx[u].slots) ?? -1) + 1) % FXTemplate.all.count
                applyTemplate(u, FXTemplate.all[next], keepOn: true)
                return
            }
            changeFX(u) { fx in
                if fx.anyOn {
                    self.modeMemory[u] = fx.slots.map(\.on)
                    for i in fx.slots.indices { fx.slots[i].on = false }
                } else {
                    let last = self.modeMemory[u] ?? []
                    for i in fx.slots.indices { fx.slots[i].on = last.contains(true) ? (i < last.count && last[i]) : true }
                }
            }
        }
    }
    /// welche Slots vor dem Ausschalten per Mode-Taste an waren (je Unit)
    private var modeMemory = [Int: [Bool]]()

    /// Vorlage in eine Unit laden (ersetzt die Slots; Plugins der alten Slots werden freigegeben)
    public func applyTemplate(_ u: Int, _ t: FXTemplate, keepOn: Bool = false) {
        locked {
            let wasOn = state.fx[u].anyOn
            setSlots(u, t.slots.map { s in
                var x = s
                x.uid = UUID()
                if keepOn { x.on = wasOn }
                return x
            })
        }
    }

    // MARK: FX-Belegung (Oberfläche und Controller gehen denselben Weg)

    private var paramIndex = [[String: Int]](repeating: [:], count: MixEngine.fxUnitCount)
    private var paramsKey = [String?](repeating: nil, count: MixEngine.fxUnitCount)
    private var paramsInst = [[ObjectIdentifier]](repeating: [], count: MixEngine.fxUnitCount)

    /// Regler oder D/W bewegt (0…1): an das zugewiesene Ziel, nicht zugewiesen = nichts
    public func setFXControl(_ u: Int, _ c: FXControl, _ v: Double) {
        runFXSet {
            guard let p = state.fxControls[u][c.slot].param else { return nil }
            return setFXParam(u, p, v)
        }
    }

    /// Taste gedrückt: Schalter um, Liste eine Stufe weiter, stufenlos zwischen min und max
    public func pressFXButton(_ u: Int, _ i: Int) {
        runFXSet {
            let info = state.fxControls[u][FXControl.button(i).slot]
            guard let p = info.param else { return nil }
            var next = info.value >= 0.5 ? 0.0 : 1.0
            if p.steps > 1 {
                let k = (info.value * Double(p.steps)).rounded() + 1
                next = k > Double(p.steps) ? 0 : k / Double(p.steps)
            }
            return setFXParam(u, p, next)
        }
    }

    /// Bedienelement zuweisen: Parameter-Schlüssel, "" = nicht zugewiesen, nil = Standard.
    /// Gilt für die Unit (Sitzung) und wird je Rack-Kennung gemerkt (EnginePrefs.fxMappings)
    public func setFXMapping(_ u: Int, _ c: FXControl, _ target: String?) {
        locked {
            state.fx[u].mapping[c] = target
            storeMapping(u)
        }
    }

    /// alle Bedienelemente der Unit auf Standard
    public func resetFXMapping(_ u: Int) {
        locked {
            state.fx[u].mapping = FXMapping()
            storeMapping(u)
        }
    }

    private func storeMapping(_ u: Int) {
        let key = state.fx[u].effectKey
        state.fx[u].mappingKey = key
        if !key.isEmpty { state.prefs.fxMappings[key] = state.fx[u].mapping.isEmpty ? nil : state.fx[u].mapping }
        applyFX(u)
    }

    /// Parameter eines Slots per Schlüssel setzen (Stellung 0…1; Parameter-Fenster eines eingebauten Effekts, Tests)
    public func setFXTarget(_ u: Int, _ id: String, _ v: Double) {
        runFXSet {
            guard let i = paramIndex[u][id] else { changeFX(u) { FXCatalog.set(id, v, &$0) }; return nil }
            return setFXParam(u, state.fxParams[u][i], v)
        }
    }

    /// Plugin-Stellung, die nach dem Entsperren gesetzt wird (Plugin-Aufrufe nie unter der Sperre)
    private struct PluginSet {
        let insts: [PluginInstance]
        let pid: AudioUnitParameterID
        let value: Float
    }

    /// FX-Änderung: der Zustand wird unter der Sperre übernommen, die Plugin-Aufrufe danach, in derselben Reihenfolge
    /// (eigene Sperre `fxSetLock`, nur für FX-Setzer; die Sperre des Controllers wird vorher freigegeben)
    private func runFXSet(_ body: () -> PluginSet?) {
        fxSetLock.lock()
        defer { fxSetLock.unlock() }
        guard let set = locked(body) else { return }
        for inst in set.insts { inst.set(set.pid, set.value) }
    }
    private let fxSetLock = NSLock()

    /// Ziel setzen: eigener Parameter -> Slot der Unit, Plugin-Parameter -> alle Instanzen des Slots (Steuer-Weg wie das Fenster)
    /// Unter der Sperre: Zustand setzen; liefert die Plugin-Stellung für `runFXSet` (nil = eingebauter Effekt)
    private func setFXParam(_ u: Int, _ p: FXParam, _ v: Double) -> PluginSet? {
        let pos = p.snapped(v)
        guard let pid = p.pluginParam else {
            changeFX(u) { FXCatalog.set(p.id, pos, &$0) }
            return nil
        }
        state.fx[u].pluginValues[p.id] = pos
        refreshControls(u)
        return PluginSet(insts: slotInsts(u, p.pluginSlot) ?? [], pid: pid, value: Float(p.plain(pos)))
    }

    /// Rack geändert: Zuweisung der neuen Kennung aus den Einstellungen, Parameterliste neu; dann Ziele auflösen
    private func prepareControls(_ u: Int, adopt: Bool = true) {
        let key = state.fx[u].effectKey
        if adopt, state.fx[u].mappingKey != key {
            state.fx[u].mapping = state.prefs.fxMappings[key] ?? FXMapping()
            state.fx[u].mappingKey = key
        }
        let slots = loadedSlots(u)
        let ids = slots.map { ObjectIdentifier($0.inst) }
        if paramsKey[u] != key || paramsInst[u] != ids {
            paramsKey[u] = key; paramsInst[u] = ids
            var plugin: [Int: (name: String, params: [FXParam])] = [:]
            for (k, inst) in slots {
                plugin[k] = (inst.info.name, inst.parameters.map { FXParam(plugin: $0, normalized: inst.isVST3, slot: k) })
            }
            let list = FXCatalog.params(state.fx[u], plugin: plugin)
            state.fxParams[u] = list
            paramIndex[u] = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        refreshControls(u)
    }

    /// geladene Plugin-Slots der Unit (Instanz des ersten Decks)
    private func loadedSlots(_ u: Int) -> [(slot: Int, inst: PluginInstance)] {
        state.fx[u].slots.indices.compactMap { k in slotInsts(u, k).map { (k, $0[0]) } }
    }

    /// Ziele der Bedienelemente auflösen und ihre Stellung lesen
    private func refreshControls(_ u: Int) {
        let fx = state.fx[u], mapping = fx.mapping, list = state.fxParams[u]
        let group = FXCatalog.groupLayout(fx)
        var out = [FXControlInfo]()
        out.reserveCapacity(FXControl.allCases.count)
        for c in FXControl.allCases {
            var info = FXControlInfo()
            let mapped = mapping[c]
            info.isDefault = mapped == nil
            if let k = mapped ?? FXCatalog.defaultTarget(c, fx: fx, params: list), let i = paramIndex[u][k] {
                let p = list[i]
                info.param = p
                info.value = fxValue(u, p)
                info.label = c.isButton && info.isDefault && (p.id == "on" || p.id.hasSuffix(".on")) ? "ON" : p.short
                // Regler auf dem Anteil eines Slots und die Gruppen-Belegung tragen den Namen des Slots (FILTER, DELAY, REVERB)
                if !c.isButton, c != .dryWet, p.pluginParam == nil, let (s, base) = FXCatalog.split(p.id), fx.slots.indices.contains(s),
                   base == "mix" || (group && info.isDefault) {
                    info.label = fx.slots[s].effect?.name ?? FXParam.shortName(slotInsts(u, s)?.first?.info.name ?? p.short)
                }
            }
            out.append(info)
        }
        if out != state.fxControls[u] { state.fxControls[u] = out }
    }

    /// Stellung eines Ziels: eigener Wert, Plugin = zuletzt gesetzter Wert. Noch nicht gelesen: Standard zeigen und das
    /// Plugin außerhalb der Sperre fragen (AU out of process: IPC); die Stellung kommt zurück und ersetzt den Standard
    private func fxValue(_ u: Int, _ p: FXParam) -> Double {
        guard let pid = p.pluginParam else { return FXCatalog.value(p.id, state.fx[u], prefs: state.prefs) ?? 0 }
        if let v = state.fx[u].pluginValues[p.id] { return v }
        guard let inst = slotInsts(u, p.pluginSlot)?.first else { return p.defaultValue }
        let key = "\(u)|\(p.id)"
        if pendingValueReads.insert(key).inserted {
            pluginReads.async { [self] in
                let v = p.position(Double(readPluginValue(inst, pid)))
                locked {
                    pendingValueReads.remove(key)
                    guard state.fx[u].pluginValues[p.id] == nil, slotInsts(u, p.pluginSlot)?.first === inst else { return }
                    state.fx[u].pluginValues[p.id] = v
                    refreshControls(u)
                }
            }
        }
        return p.defaultValue
    }

    // MARK: Slots und Plugins
    // Je Unit (0…3, Master-Bus = masterBus) bis zu MixEngine.slotCount Slots in Reihe. Eingebaute Effekte rechnet der Kern
    // mit seiner Instanz je Unit, Plugins: je Slot eine Instanz pro Deck (Master: eine). Auch nicht zugewiesene Decks haben
    // Instanzen (Zuweisen wirkt sofort, ohne Ladepause). Laden auf eigener Queue außerhalb der Sperre (Plugins brauchen teils
    // lange), Einsetzen unter der Sperre; herausgenommene Instanzen werden erst frei, wenn der Audio-Thread sie nicht mehr rechnet.

    /// Slots des Master-Busses (Index nach den FX-Units)
    public static let masterBus = MixEngine.fxUnitCount
    private static let busCount = MixEngine.fxUnitCount + 1

    /// geladener Plugin-Slot: Instanzen aller Decks (Master: eine); folgen dem Slot beim Verschieben
    private final class LoadedSlot {
        var uid: UUID
        let insts: [PluginInstance]
        init(uid: UUID, insts: [PluginInstance]) { self.uid = uid; self.insts = insts }
        var id: String { insts[0].info.id }
    }
    private var loaded = [[LoadedSlot]](repeating: [], count: busCount)
    /// Slot → laufender Ladeauftrag bzw. Plugin-ID, die nicht lud
    private var loading = [[UUID: Int]](repeating: [:], count: busCount)
    private var failed = [[UUID: String]](repeating: [:], count: busCount)
    private var loadToken = 0
    /// Stand im Kern je Unit × Deck × Slot (Plugins) und die Effekte der Slots
    private var installed: [[[PluginInstance?]]] = (0..<busCount).map { b in
        Array(repeating: Array(repeating: nil, count: MixEngine.slotCount), count: b == MixEngine.fxUnitCount ? 1 : MixEngine.deckCount)
    }
    private var installedKinds = [[Int32]?](repeating: nil, count: busCount)
    private let pluginQueue = DispatchQueue(label: "minos741.plugins", qos: .userInitiated)
    private let pluginEvents = DispatchQueue(label: "minos741.plugin-events", qos: .userInitiated)
    /// Stellungen, die noch vom Plugin gelesen werden (Schlüssel: Unit|Ziel); Lesen nie unter der Sperre
    private let pluginReads = DispatchQueue(label: "minos741.plugin-reads", qos: .userInitiated)
    private var pendingValueReads = Set<String>()
    /// Test-Naht: liest den Wert eines Plugin-Parameters (auf der Lese-Queue, nie unter der Sperre)
    var readPluginValue: (PluginInstance, AudioUnitParameterID) -> Float = { $0.value($1) }
    /// Plugin-Liste, Einstellungen, Absturz-Markierung (die App setzt vor dem ersten Laden eine gespeicherte ein)
    public var pluginCatalog = PluginCatalog(directory: nil) {
        didSet { observeInvalidation() }
    }
    private var invalidationObserver: NSObjectProtocol?

    private func slots(_ b: Int) -> [FXSlot] { b == Self.masterBus ? state.masterFX.slots : state.fx[b].slots }
    private func editSlots(_ b: Int, _ f: (inout [FXSlot]) -> Void) {
        if b == Self.masterBus { f(&state.masterFX.slots) } else { f(&state.fx[b].slots) }
    }
    private func coreUnit(_ b: Int) -> Int { b == Self.masterBus ? MixEngine.masterUnit : b }
    private func busName(_ b: Int) -> String { b == Self.masterBus ? "MASTER" : "FX \(b + 1)" }
    private func applyBus(_ b: Int) { if b == Self.masterBus { applyMasterFX() } else { applyFX(b) } }

    /// LIVE und Einstellung „VST3 bei LIVE überbrücken“ (`LiveBypass`); die App setzt sie bei jeder Änderung
    private var liveMode = false, liveBypassVST3 = false

    public func setLiveBypass(live: Bool, vst3: Bool) {
        locked {
            guard live != liveMode || vst3 != liveBypassVST3 else { return }
            liveMode = live; liveBypassVST3 = vst3
            for b in 0...Self.masterBus { applyBus(b) }
        }
    }

    /// Slot hält eine VST3-Instanz und ist bei LIVE überbrückt
    private func isLiveBypassed(_ b: Int, _ k: Int) -> Bool {
        LiveBypass.bypassed(live: liveMode, enabled: liveBypassVST3, vst3InProcess: slotInsts(b, k)?.first?.isVST3 ?? false)
    }

    /// Überbrückte Plugin-Slots einer Unit (Master: `masterBus`) trocken an den Kern: Schalter aus, der Kern blendet aus
    private func liveBypassed(_ b: Int, _ fx: FXUnitState) -> FXUnitState {
        var x = fx
        for k in x.slots.indices { x.slots[k].on = LiveBypass.effectiveOn(x.slots[k].on, bypassed: isLiveBypassed(b, k)) }
        return x
    }

    /// Namen der Plugin-Slots, die gerade bei LIVE überbrückt sind (eingeschaltet, VST3 geladen)
    public func liveBypassNames() -> [String] {
        locked {
            (0...Self.masterBus).flatMap { b in
                slots(b).indices.compactMap { k in
                    slots(b)[k].on && isLiveBypassed(b, k) ? slotInsts(b, k)?.first?.info.name : nil
                }
            }
        }
    }

    /// Instanzen des k-ten Slots (alle Decks), nil = kein Plugin oder (noch) nicht geladen
    private func slotInsts(_ b: Int, _ k: Int) -> [PluginInstance]? {
        let c = slots(b)
        guard c.indices.contains(k), c[k].isPlugin else { return nil }
        return loaded[b].first { $0.uid == c[k].uid && $0.id == c[k].id }?.insts
    }

    /// Effekt-Plugins fürs FX-Menü: eingeschaltet und nicht blockiert (einmal eingelesen, `refresh` liest neu)
    public func pluginList(refresh: Bool = false) -> [PluginInfo] { pluginCatalog.menuList(refresh: refresh) }

    /// Beschriftung der Regler 1–3, soweit sie auf Plugin-Parametern liegen (leer, solange kein Plugin geladen ist)
    public func pluginParamNames(_ u: Int) -> [String] {
        locked { (1...3).compactMap { state.fxControls[u][$0].param?.pluginParam != nil ? state.fxControls[u][$0].label : nil } }
    }

    /// Anzeige eines Plugin-Werts vom Plugin selbst (VST3; außerhalb der Sperre, Haupt-Thread). Sonst nil
    public func pluginText(_ u: Int, _ p: FXParam, _ pos: Double) -> String? {
        guard let pid = p.pluginParam, let inst = locked({ slotInsts(u, p.pluginSlot)?.first }), inst.isVST3 else { return nil }
        let t = inst.text(pid, Float(p.plain(pos)))
        return p.unit.isEmpty || t.hasSuffix(p.unit) ? t : t + " " + p.unit
    }

    // MARK: Slots bearbeiten (FX-Unit 0…3 oder masterBus)

    /// alle Slots ersetzen (Vorlage, Rack, Tests); Plugin-Werte und Belegung beginnen neu
    public func setSlots(_ b: Int, _ list: [FXSlot]) {
        locked {
            editSlots(b) { $0 = FXRules.valid(list) }
            failed[b] = [:]   // nochmals gewählt = neuer Versuch
            state.pluginErrors[b] = nil
            if b < Self.masterBus { state.fx[b].pluginValues = [:] }
            applyBus(b)
        }
    }

    /// Effekt hinten anhängen (höchstens MixEngine.slotCount; ein eingebauter, der schon im Rack steht, bleibt wo er ist)
    @discardableResult
    public func addSlot(_ b: Int, id: String) -> Bool {
        locked {
            let c = slots(b)
            guard c.count < MixEngine.slotCount, FXUnitState.Effect(builtin: id) == nil || !c.contains(where: { $0.id == id }) else { return false }
            changeSlots(b, perm: c.indices.map { Optional($0) }) { $0.append(FXTemplate.slot(id)) }
            state.pluginErrors[b] = nil
            applyBus(b)
            return true
        }
    }

    /// Slot k durch einen anderen Effekt ersetzen (an/aus bleibt, Einstellungen beginnen neu). Ein eingebauter Effekt, der
    /// schon in einem anderen Slot steht, tauscht mit k den Platz
    public func replaceSlot(_ b: Int, slot k: Int, id: String) {
        locked {
            guard slots(b).indices.contains(k), slots(b)[k].id != id else { return }
            var list = slots(b)
            let perm = FXRules.replace(&list, at: k, with: id)
            changeSlots(b, perm: perm) { $0 = list }
            state.pluginErrors[b] = nil
            applyBus(b)
        }
    }

    /// Slot k herausnehmen (eingebaut: klingt aus, Plugin: Instanzen frei, sobald der Kern sie nicht mehr rechnet)
    public func removeSlot(_ b: Int, slot k: Int) {
        locked {
            guard slots(b).indices.contains(k) else { return }
            let perm: [Int?] = slots(b).indices.map { $0 == k ? nil : ($0 > k ? $0 - 1 : $0) }
            changeSlots(b, perm: perm) { $0.remove(at: k) }
            if !slots(b).contains(where: \.isPlugin) { state.pluginErrors[b] = nil }
            applyBus(b)
        }
    }

    /// Slot k um `by` verschieben (−1 = früher im Signalfluss)
    public func moveSlot(_ b: Int, slot k: Int, by: Int) { moveSlot(b, from: k, to: k + by) }

    /// Slot von `from` nach `to` (Ziehen); die anderen rücken nach
    public func moveSlot(_ b: Int, from k: Int, to j: Int) {
        locked {
            let c = slots(b)
            guard c.indices.contains(k), c.indices.contains(j), k != j else { return }
            var order = Array(c.indices)
            order.insert(order.remove(at: k), at: j)
            var perm = [Int?](repeating: nil, count: c.count)
            for (n, o) in order.enumerated() { perm[o] = n }
            changeSlots(b, perm: perm) { s in s = order.map { c[$0] } }
            applyBus(b)
        }
    }

    /// Slot an/aus (aus = durchgereicht, Fahne klingt aus)
    public func setSlotOn(_ b: Int, slot k: Int, _ on: Bool) {
        locked {
            guard slots(b).indices.contains(k) else { return }
            editSlots(b) { $0[k].on = on }
            applyBus(b)
        }
    }

    /// D/W eines Slots (0…1)
    public func setSlotMix(_ b: Int, slot k: Int, _ v: Double) {
        locked {
            guard slots(b).indices.contains(k) else { return }
            editSlots(b) { $0[k].mix = max(0, min(1, v)) }
            applyBus(b)
        }
    }

    /// Parameter eines eingebauten Effekts im Slot (Stellung 0…1)
    public func setSlotParam(_ b: Int, slot k: Int, _ id: String, _ v: Double) {
        locked {
            guard slots(b).indices.contains(k), let e = slots(b)[k].effect,
                  let p = FXCatalog.builtinParams(e).first(where: { $0.id == id }) else { return }
            editSlots(b) { $0[k].params[id] = p.snapped(v) }
            applyBus(b)
        }
    }

    /// Stellung eines Slot-Parameters (eingebaut, mit den Einstellungen als Standard)
    public func slotParam(_ b: Int, slot k: Int, _ id: String) -> Double {
        locked { slots(b).indices.contains(k) ? FXCatalog.param(slots(b)[k], id, prefs: state.prefs) : 0 }
    }

    /// Slots ändern; `perm[alt] = neu` (nil = Slot entfällt). Gemerkte Plugin-Werte und die Belegung folgen ihrem Slot;
    /// gibt es für das neue Rack eine gemerkte Belegung, gilt die
    private func changeSlots(_ b: Int, perm: [Int?], _ f: (inout [FXSlot]) -> Void) {
        guard b < Self.masterBus else { editSlots(b, f); return }
        let oldKey = state.fx[b].effectKey, ownMapping = state.fx[b].mappingKey == oldKey
        editSlots(b, f)
        var fx = state.fx[b]
        let move = { (key: String) -> String? in
            guard let (k, base) = FXCatalog.split(key) else { return key }
            guard k < perm.count, let n = perm[k] else { return nil }
            return FXCatalog.prefix(n) + base
        }
        fx.pluginValues = Dictionary(fx.pluginValues.compactMap { k, v in move(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        let key = fx.effectKey
        // Belegung mitnehmen, solange ein Slot bleibt (sonst ist es ein anderes Rack: dessen Belegung bzw. Standard)
        if ownMapping, key != oldKey, state.prefs.fxMappings[key] == nil, perm.contains(where: { $0 != nil }) {
            var m = FXMapping()
            for (c, t) in fx.mapping.targets { if let n = t.isEmpty ? t : move(t) { m.targets[c] = n } }
            fx.mapping = m
            fx.mappingKey = key
        }
        state.fx[b] = fx
    }

    /// Rack merken (Plugin-Zustände frisch aus den Plugins); gilt für jede FX-Unit und den Master-Bus
    public func saveRack(_ b: Int, name: String) {
        let snap: [(FXSlot, PluginInstance?)] = locked { slots(b).indices.map { (slots(b)[$0], slotInsts(b, $0)?.first) } }
        // VST3 liest den Zustand auf dem UI-Thread: außerhalb der Sperre
        let list = snap.map { s, inst -> FXSlot in
            var x = s
            if let st = inst?.state { x.state = st }
            return x
        }
        locked { state.prefs.pluginChains[name] = list.isEmpty ? nil : list }
    }

    /// gemerktes Rack laden (ersetzt die Slots, Belegung des Racks aus den Einstellungen)
    public func loadRack(_ b: Int, name: String) {
        locked {
            guard let p = state.prefs.pluginChains[name] else { return }
            setSlots(b, p.map { var x = $0; x.uid = UUID(); return x })
        }
    }

    public func deleteRack(_ name: String) { locked { state.prefs.pluginChains[name] = nil } }

    /// Latenz je Slot und Summe in Sekunden (Plugins; nicht ausgeglichen, Anzeige)
    public func rackLatency(_ b: Int) -> (slots: [Double?], total: Double) {
        let insts = locked { slots(b).indices.map { slotInsts(b, $0)?.first } }
        let l = insts.map { $0?.latency }
        return (l, l.reduce(0) { $0 + ($1 ?? 0) })
    }

    /// Instanz des ersten Decks eines Plugin-Slots (nil = nicht geladen), ohne Zuhören
    public func pluginInstance(_ b: Int, slot k: Int) -> PluginInstance? { locked { slotInsts(b, k)?.first } }

    /// Slot lädt noch bzw. lud nicht (Plugin-ID)
    public func slotLoading(_ b: Int, slot k: Int) -> (loading: Bool, failed: Bool) {
        locked {
            let c = slots(b)
            guard c.indices.contains(k), c[k].isPlugin else { return (false, false) }
            return (loading[b][c[k].uid] != nil, failed[b][c[k].uid] != nil)
        }
    }

    /// Instanz für das Plugin-Fenster (die des ersten Decks); Änderungen darin gehen live an die anderen Decks des Slots
    public func beginPluginEdit(_ b: Int, slot k: Int = 0) -> PluginInstance? {
        guard let first = locked({ slotInsts(b, k)?.first }) else { return nil }
        // Zuhörer beim Plugin anmelden (AU: pro Parameter ein Aufruf an den Dienst) – außerhalb der Sperre
        first.observe(on: pluginEvents) { [weak self, weak first] id, v in
            guard let self, let first else { return }
            self.pluginParamChanged(b, first, id, v)
        }
        return first
    }

    /// Fenster zu: Zuhören beenden, Zustand für die Sitzung merken (VST3: Zustand auf dem UI-Thread, außerhalb der Sperre)
    public func endPluginEdit(_ b: Int, _ inst: PluginInstance) {
        inst.stopObserving()
        let st = inst.state
        locked {
            guard let st, let k = slots(b).indices.first(where: { slotInsts(b, $0)?.contains { $0 === inst } == true }) else { return }
            editSlots(b) { $0[k].state = st }
        }
    }

    private func pluginParamChanged(_ b: Int, _ src: PluginInstance, _ id: AudioUnitParameterID, _ v: Float) {
        // die anderen Instanzen des Slots nachziehen: Plugin-Aufrufe außerhalb der Sperre (auf der Ereignis-Queue)
        let others = locked { () -> [PluginInstance] in
            guard let k = slots(b).indices.first(where: { slotInsts(b, $0)?.contains { $0 === src } == true }) else { return [] }
            return slotInsts(b, k)?.filter { $0 !== src } ?? []
        }
        for p in others where p.value(id) != v { p.set(id, v) }
        locked {
            guard b < Self.masterBus, let k = slots(b).indices.first(where: { slotInsts(b, $0)?.contains { $0 === src } == true }) else { return }
            // Bedienelemente folgen dem Fenster; gemerkte Stellungen bleiben aktuell
            let key = FXParam.pluginKey(id, slot: k)
            guard state.fx[b].pluginValues[key] != nil || state.fxControls[b].contains(where: { $0.param?.id == key }),
                  let par = src.parameters.first(where: { $0.id == id }) else { return }
            state.fx[b].pluginValues[key] = FXParam(plugin: par).position(Double(v))
            refreshControls(b)
        }
    }

    /// Slots mit dem Kern abgleichen: fehlende Plugins laden, Belegung und Instanzen einsetzen, herausgenommene freigeben.
    /// Unter der Sperre
    private func syncRack(_ b: Int) {
        let want = Array(slots(b).prefix(MixEngine.slotCount))
        let plugs = want.filter(\.isPlugin)
        let uids = Set(plugs.map(\.uid))
        // Sitzung neu übernommen (neue Slot-Kennungen): geladene Instanzen mit derselben Plugin-ID weiterverwenden
        for s in plugs where !loaded[b].contains(where: { $0.uid == s.uid }) && loading[b][s.uid] == nil {
            if let l = loaded[b].first(where: { !uids.contains($0.uid) && $0.id == s.id }) { l.uid = s.uid }
        }
        loaded[b].removeAll { l in !plugs.contains { $0.uid == l.uid && $0.id == l.id } }
        loading[b] = loading[b].filter { uids.contains($0.key) }
        failed[b] = failed[b].filter { u, id in plugs.contains { $0.uid == u && $0.id == id } }
        for (k, s) in want.enumerated() where s.isPlugin && !loaded[b].contains(where: { $0.uid == s.uid }) {
            guard loading[b][s.uid] == nil, failed[b][s.uid] == nil else { continue }
            startLoad(b, s, slot: k)
        }
        let ready = want.map { s in !s.isPlugin || loaded[b].contains { $0.uid == s.uid } }
        if state.slotReady[b] != ready { state.slotReady[b] = ready }
        // Kern: Slot k = Effekt des k-ten Slots, Plugin-Slots mit ihrer Instanz (noch nicht geladen = durchgereicht)
        let kinds = want.map { $0.effect?.kind ?? FXUnitState.Effect.plugin.kind }
        let kindsChanged = installedKinds[b] != kinds
        installedKinds[b] = kinds
        for d in installed[b].indices {
            var row = [PluginInstance?](repeating: nil, count: MixEngine.slotCount)
            for (k, s) in want.enumerated() where s.isPlugin { row[k] = loaded[b].first { $0.uid == s.uid }?.insts[d] }
            let old = installed[b][d]
            guard kindsChanged || !zip(old, row).allSatisfy({ $0 === $1 }) else { continue }
            installed[b][d] = row
            engine.setRack(unit: coreUnit(b), deck: d, kinds: kinds, plugins: row)
            for case let o? in old where !row.contains(where: { $0 === o }) { retirePlugin(o, unit: coreUnit(b), deck: d) }
        }
    }

    private func startLoad(_ b: Int, _ s: FXSlot, slot k: Int) {
        let want = s.id, uid = s.uid
        // blockiert (Absturz) oder abgeschaltet: nicht laden, auch nicht aus einer gespeicherten Sitzung
        if let why = pluginCatalog.unusableReason(want) {
            failed[b][uid] = want
            state.pluginErrors[b] = why
            onNotice?(EngineNotice(.warning, key: "plugin.\(b)", busName(b) + ": " + String(localized: "Plugin nicht geladen · \(why)")))
            return
        }
        loadToken += 1
        let token = loadToken, saved = s.state, rate = engine.sampleRate, name = busName(b)
        let count = installed[b].count
        loading[b][uid] = token
        let catalog = pluginCatalog
        pluginQueue.async { [self] in
            do {
                // Liste ggf. erst hier einlesen (außerhalb der Sperre)
                guard let info = catalog.info(want) ?? PluginHost.codes(want).map({
                    PluginInfo(id: want, name: PluginHost.fourCC($0.1), manufacturer: PluginHost.fourCC($0.2), type: $0.0, subtype: $0.1, manu: $0.2)
                }) else { throw NSError(domain: "minos741.plugin", code: 2, userInfo: [NSLocalizedDescriptionKey: want]) }
                // live: Fremd-Plugins nur isoliert; nur im Prozess ladbare (VST3, eigener Ordner) erst nach Freigabe
                if let why = catalog.inProcessReason(want) ?? catalog.unusableReason(want) {
                    throw NSError(domain: "minos741.plugin", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(info.name): \(why)"])
                }
                let isolated = catalog.isolated(want)
                print("[plugin] \(name) Slot \(k + 1): \(info.name) \(isolated ? "isoliert" : "im Prozess")")
                // Absturz-Markierung: stürzt MINOS-741 beim Öffnen ab, ist das Plugin beim nächsten Start blockiert
                catalog.beginOpen(key: want, name: info.name)
                defer { catalog.endOpen() }
                let insts = try (0..<count).map { _ -> PluginInstance in
                    let p = try PluginInstance(info, sampleRate: rate, outOfProcess: isolated)
                    if let saved { p.state = saved }
                    _ = p.parameters
                    return p
                }
                // Zustand hier lesen, nicht unter der Sperre (VST3 fragt den UI-Thread)
                finishSlotLoad(b, uid, token, insts, restored: saved != nil, initialState: saved ?? insts[0].state)
            } catch {
                locked {
                    guard loading[b][uid] == token else { return }
                    loading[b][uid] = nil; failed[b][uid] = want
                    state.pluginErrors[b] = error.localizedDescription
                    onNotice?(EngineNotice(.error, key: "plugin.\(b)",
                                           name + ": " + String(localized: "Plugin nicht ladbar · \(error.localizedDescription)")))
                }
            }
        }
    }

    private func finishSlotLoad(_ b: Int, _ uid: UUID, _ token: Int, _ insts: [PluginInstance], restored: Bool, initialState: Data?) {
        locked {
            // inzwischen anders gewählt: die neuen Instanzen waren nie im Kern → einfach verwerfen
            guard loading[b][uid] == token, let k = slots(b).firstIndex(where: { $0.uid == uid && $0.id == insts[0].info.id }) else { return }
            loading[b][uid] = nil; failed[b][uid] = nil; state.pluginErrors[b] = nil
            loaded[b].append(LoadedSlot(uid: uid, insts: insts))
            // Sitzung: Stellungen der Bedienelemente wieder setzen (neuer als der gespeicherte Zustand); neues Plugin: frisch
            if b < Self.masterBus {
                if restored { pushPluginValues(b, slot: k, insts) } else { dropPluginValues(b, slot: k) }
            }
            if slots(b)[k].state == nil { editSlots(b) { $0[k].state = initialState } }
            applyBus(b)
        }
    }

    /// gemerkte Stellungen eines Slots an die neuen Instanzen ("@i" aus älteren Sitzungen = i-ter Parameter)
    private func pushPluginValues(_ u: Int, slot k: Int, _ insts: [PluginInstance]) {
        let params = insts[0].parameters
        var out = state.fx[u].pluginValues.filter { FXParam.pluginSlot(of: $0.key)?.0 != k }
        for (key, v) in state.fx[u].pluginValues {
            guard let (s, base) = FXParam.pluginSlot(of: key), s == k else { continue }
            let par = base.hasPrefix("@")
                ? Int(base.dropFirst()).flatMap { $0 < params.count ? params[$0] : nil }
                : UInt32(base.dropFirst()).flatMap { id in params.first { $0.id == id } }
            guard let par else { continue }
            let p = FXParam(plugin: par, slot: k)
            for inst in insts { inst.set(par.id, Float(p.plain(v))) }
            out[p.id] = v
        }
        state.fx[u].pluginValues = out
    }

    private func dropPluginValues(_ u: Int, slot k: Int) {
        state.fx[u].pluginValues = state.fx[u].pluginValues.filter { FXParam.pluginSlot(of: $0.key)?.0 != k }
    }

    /// alte Instanz halten, bis der Audio-Thread einen Block ohne sie gerechnet hat (steht die Ausgabe, rechnet niemand)
    private func retirePlugin(_ old: PluginInstance, unit u: Int, deck d: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            if engine.pluginReleased(unit: u, deck: d, old) || !engine.running { return }
            retirePlugin(old, unit: u, deck: d)
        }
    }

    // MARK: Master-Bus

    /// Master-Bus an/aus, Dry/Wet; die Slots bearbeiten addSlot & Co. mit `masterBus`
    public func setMasterFX(on: Bool? = nil, dryWet: Double? = nil) {
        locked {
            if let on { state.masterFX.on = on }
            if let dryWet { state.masterFX.dryWet = max(0, min(1, dryWet)) }
            applyMasterFX()
        }
    }

    public func toggleMasterFX() { locked { state.masterFX.on.toggle(); applyMasterFX() } }

    /// Slots und Schalter an den Kern (aus = jeder Slot aus, Fahnen klingen aus); Paar = Master-Paar des internen Mixers.
    /// Extern gibt es keinen Summenpunkt: aus
    private func applyMasterFX() {
        syncRack(Self.masterBus)
        let m = state.masterFX
        let fx = liveBypassed(Self.masterBus, FXUnitState(slots: m.slots.map { s in var x = s; x.on = s.on && m.on; return x }, dryWet: m.dryWet))
        applyCoreFX(unit: MixEngine.masterUnit, deck: 0, fx, assigned: true)
        engine.setMasterFXChannel(state.externalMixer ? nil : engine.routing.firstChannel.first)
    }

    /// NaN im Deck oder aus einem Plugin: Slot zurücksetzen, solange reicht der Kern ihn durch. Unter der Sperre.
    /// Das Zurücksetzen selbst läuft außerhalb (VST3: UI-Thread, AU: Plugin-Queue – bei isolierten Plugins ein
    /// XPC-Aufruf, der den Steuertakt nicht aufhalten darf)
    private var pluginsResetting = Set<Int>()
    private func healPlugins() {
        for b in installed.indices {
            let unit = coreUnit(b)
            for d in installed[b].indices {
                for k in 0..<MixEngine.slotCount where engine.slotNeedsReset(unit: unit, deck: d, slot: k) {
                    let key = (b * 16 + d) * 16 + k
                    guard !pluginsResetting.contains(key) else { continue }
                    guard let p = installed[b][d][k] else { engine.slotResetDone(unit: unit, deck: d, slot: k); continue }
                    pluginsResetting.insert(key)
                    let done = { [weak self] in
                        guard let self else { return }
                        self.engine.slotResetDone(unit: unit, deck: d, slot: k)
                        self.locked { _ = self.pluginsResetting.remove(key) }
                    }
                    if p.isVST3 { p.reset(done) } else { pluginQueue.async { p.reset(done) } }
                }
            }
        }
    }

    /// isoliertes Plugin abgestürzt (der Systemdienst ist weg, MINOS-741 läuft weiter): Instanzen heraus, Plugin blockieren
    private func observeInvalidation() {
        if invalidationObserver != nil { return }
        let name = NSNotification.Name(kAudioComponentInstanceInvalidationNotification as String)
        invalidationObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] n in
            guard let self, let v = n.userInfo?["audioUnit"] as? NSValue, let raw = v.pointerValue else { return }
            self.pluginInvalidated(OpaquePointer(raw))
        }
    }

    private func pluginInvalidated(_ au: OpaquePointer) {
        locked {
            for b in loaded.indices {
                for l in loaded[b] {
                    guard let hit = l.insts.first(where: { OpaquePointer($0.audioUnit) == au }) else { continue }
                    pluginDown(b, l.uid, hit, crashed: true)
                }
            }
        }
    }

    /// isoliertes Plugin abgestürzt oder hängt (rechnet seit `hangSeconds` keinen Block): Instanzen des Platzes heraus
    /// (durchgereicht), Absturz zählen, Hinweis; unter `PluginCatalog.crashLimit` nach 2 s neu laden, sonst gesperrt. Unter der Sperre
    private func pluginDown(_ b: Int, _ uid: UUID, _ hit: PluginInstance, crashed: Bool) {
        let id = hit.info.id
        // ein Absturz trifft alle Instanzen im selben Dienst (mehrere Meldungen, auch für andere Plätze): einmal zählen
        let now = Date()
        let n: Int
        if let t = lastPluginCrash[id], now.timeIntervalSince(t) < 1 {
            n = pluginCatalog.settings.crashes[id] ?? 1
        } else {
            n = pluginCatalog.recordCrash(id)
        }
        lastPluginCrash[id] = now
        loaded[b].removeAll { $0.uid == uid }
        loading[b][uid] = nil; failed[b][uid] = id
        let what = crashed ? String(localized: "abgestürzt") : String(localized: "antwortet nicht")
        let limit = PluginCatalog.crashLimit
        if n >= limit {
            state.pluginErrors[b] = String(format: String(localized: "%@ %@ (%lld×) – blockiert"), hit.info.name, what, n)
        } else {
            state.pluginErrors[b] = String(format: String(localized: "%@ %@ (%lld/%lld) – trocken, lädt neu"), hit.info.name, what, n, limit)
            controlQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.locked {
                    guard self.failed[b][uid] == id else { return }
                    self.failed[b][uid] = nil
                    self.applyBus(b)
                }
            }
        }
        print("[plugin] \(busName(b)): \(hit.info.name) \(crashed ? "abgestürzt" : "hängt") (\(n)/\(limit))")
        onNotice?(EngineNotice(n >= limit ? .error : .warning, key: "plugin.\(b)", busName(b) + ": " + (state.pluginErrors[b] ?? "")))
        applyBus(b)
    }
    private var lastPluginCrash: [String: Date] = [:]
    /// gemeldete Fehlblöcke je Kette (Hinweis nur bei neuen)
    private var pluginFailuresSeen = [UInt64](repeating: 0, count: busCount)
    /// isoliertes Plugin, das so lange am Stück keinen Block liefert, gilt als hängend
    static let pluginHangSeconds = 2.0

    /// 1 Hz: isolierte Plugins, die Blöcke nicht rechnen (Zeitüberschreitung des Dienstes) -> Hinweis, hängend -> pluginDown
    private func checkPluginFailures() {
        for b in loaded.indices {
            let insts = loaded[b].flatMap { l in l.insts.filter(\.outOfProcess).map { (l.uid, $0) } }
            guard !insts.isEmpty else { pluginFailuresSeen[b] = 0; continue }
            let f = insts.map(\.1.renderFailures)
            let blocks = f.reduce(0) { $0 + $1.blocks }
            if let worst = insts.indices.max(by: { f[$0].seconds < f[$1].seconds }), f[worst].seconds >= Self.pluginHangSeconds {
                pluginDown(b, insts[worst].0, insts[worst].1, crashed: false)
                pluginFailuresSeen[b] = 0
                continue
            }
            if blocks > pluginFailuresSeen[b] {
                let name = insts[0].1.info.name
                onNotice?(EngineNotice(.warning, key: "plugin.\(b)", b == Self.masterBus
                    ? String(format: String(localized: "MASTER: %@ antwortet nicht rechtzeitig – %lld Blöcke trocken"), name, Int(blocks))
                    : String(format: String(localized: "FX %lld: %@ antwortet nicht rechtzeitig – %lld Blöcke trocken"), b + 1, name, Int(blocks))))
            }
            pluginFailuresSeen[b] = blocks
        }
    }

    // MARK: Steuertakt (200 Hz, Steuer-Queue)

    private func tick() {
        var expired: [PendingLoad] = [], slow: [PendingLoad] = []
        let handlers: [(MixController) -> Void] = locked {
            state.autoMaster = state.effectiveMaster   // Auto-Master klebt am laufenden Deck
            let master = state.effectiveMaster
            // Link folgen: nur mit Link-Teilnehmern (die Pair-Verbindung setzt linkFollow); sonst führt MINOS wie bisher
            let following = state.linkEnabled && state.linkFollow && link.peers > 0
            state.linkFollowing = following
            if following != linkWasFollowing { linkWasFollowing = following; link.resetPolicies() }
            for d in state.decks.indices {
                let p = engine.player(d)
                if state.decks[d].playing != p.playing, !state.decks[d].cueHeld {
                    state.decks[d].playing = p.playing
                    applyRate(d)
                }
                checkActiveLoops(d)
                let hasMaster = state.clockIsMaster || (master != nil && master != d)
                guard state.decks[d].sync, state.decks[d].playing, hasMaster,
                      let g = state.decks[d].grid, g.bpm > 0 else {
                    if state.decks[d].nudge != 0, !state.decks[d].sync { state.decks[d].nudge = 0; applyRate(d) }
                    continue
                }
                let target = (state.masterTempo / g.bpm - 1) * 100
                var changed = abs(target - state.decks[d].tempoPct) > 0.0001
                state.decks[d].tempoPct = target
                // rückwärts (Flux-Reverse, Reverse) nicht nachziehen – beim Loslassen kommt die Flux-Position, die bleibt in Phase
                if state.prefs.phaseLock, state.prefs.syncMode != .tempo, !state.decks[d].reverse, state.decks[d].bend == 0, !state.decks[d].grab,
                   let e = phaseErrorLocked(d) {
                    // harter Sprung nur, wenn der Fehler groß ist und > 100 ms anhält – sonst weich nachziehen
                    bigError[d] = abs(e) > 0.25 ? bigError[d] + 1 : 0
                    if bigError[d] >= 20 {
                        jump(d, to: inRangeKeepingPhase(d, position(d) - e * g.beat, beat: g.beat), "phase lock")
                        state.decks[d].nudge = 0
                        bigError[d] = 0
                    } else {
                        let n = abs(e) < 0.004 ? 0 : max(-0.06, min(0.06, -e * 0.6))
                        changed = changed || n != state.decks[d].nudge
                        state.decks[d].nudge = n
                    }
                }
                if changed { applyRate(d) }
            }
            // AUTO-Modus: Clock folgt Tempo und Phase des Master-Decks (für Metronom und Link)
            var clockOnDeck = false
            if !state.clockIsMaster, let m = master, let g = state.decks[m].grid, state.decks[m].playing {
                clockOnDeck = true
                // Tempo-Schwelle wie bei Link (0,0005 BPM): 0,005 ließ die Clock dem Deck um ~0,02 Beats in 4 min
                // davonlaufen, jeder Rücksprung war eine Link-Neusetzung
                let bpm = state.decks[m].bpm
                if abs(bpm - state.clockBPM) > 0.0005 { state.clockBPM = bpm; engine.setClockBPM(bpm) }
                // Beat-Phase sofort; Takt-Lage (Takt-Eins der Clock = Takt-Eins des Decks, sonst läuft Link um 1–3 Beats
                // versetzt) erst, wenn der Versatz 0,5 s gleich bleibt – ein Loop kürzer als ein Takt darf die Clock
                // nicht bei jedem Durchlauf springen lassen
                let want = g.beatPosition(at: position(m))
                let bar = BeatGrid.barPhaseError(own: engine.clockBeat, master: want)
                if abs(BeatGrid.phaseError(own: engine.clockBeat, master: want)) > 0.02 {
                    jumpClock(to: want); clockBarTicks = 0
                } else if abs(bar) > 0.02, abs(bar - clockBarLast) < 0.05 {
                    clockBarTicks += 1
                    if clockBarTicks >= 100 { jumpClock(to: want); clockBarTicks = 0 }
                } else { clockBarTicks = 0 }
                clockBarLast = bar
            }
            // Link: Tempo und Beat der Clock vorgeben, Teilnehmer zählen. Läuft die Clock frei, zieht MINOS kleine
            // Abweichungen an der eigenen Clock nach (Link-Zeitachse bleibt für die Teilnehmer ruhig)
            if state.linkEnabled {
                if let st = engine.clockStamp {
                    link.offsetMicros = Int64(state.prefs.linkOffsetMs * 1000)
                    if following {
                        // Folgen: Tempo und Takt von Link, Link selbst bleibt unberührt
                        if let f = link.follow(beat: st.beat, hostTime: st.hostTime) {
                            if f.bpm > 0, abs(f.bpm - state.clockBPM) > 0.0005 { state.clockBPM = f.bpm; engine.setClockBPM(f.bpm) }
                            switch f.action {
                            case .trim(let d): engine.trimClock(-d)
                            case .jump(let d): jumpClock(to: engine.clockBeat - d); clockBarTicks = 0
                            case .none: break
                            }
                        }
                    } else if case .trim(let d) = link.lead(bpm: state.clockBPM, beat: st.beat, hostTime: st.hostTime, canTrim: !clockOnDeck) {
                        engine.trimClock(-d)
                    }
                    if link.stats.forces != state.linkForces { state.linkForces = link.stats.forces }
                }
                linkTicks += 1
                if linkTicks % 100 == 0 { let n = link.peers; if n != state.linkPeers { state.linkPeers = n } }
            } else if state.linkPeers != 0 || state.linkForces != 0 { state.linkPeers = 0; state.linkForces = 0 }
            // Bar-Zähler startet mit dem ersten Play
            if sessionOffset == nil, state.decks.contains(where: { $0.playing }) { sessionOffset = -engine.clockBeat.rounded() }
            // History: hörbare Spielzeit zählen, ab Schwelle als gespielt melden
            var played: [(Int, Track, Date)] = []
            for d in state.decks.indices where state.decks[d].playing {
                guard let t = state.decks[d].track else { continue }
                if playStart[d] == nil { playStart[d] = Date() }
                if audible(d) { playedTime[d] += 0.005 }
                if !playedLogged[d], playedTime[d] >= state.prefs.historyThreshold {
                    playedLogged[d] = true
                    played.append((d, t, playStart[d] ?? Date()))
                }
            }
            if !played.isEmpty, let cb = onPlayed { DispatchQueue.global().async { for p in played { cb(p.0, p.1, p.2) } } }
            tickCount += 1
            if tickCount % 4 == 0 { healPlugins() }
            if tickCount % 200 == 0 { checkPluginFailures() }
            // beat-synchrones Delay folgt dem Tempo
            if tickCount % 50 == 0 {
                let delayOn = { (s: [FXSlot]) in s.contains { $0.effect == .delay && $0.on } }
                if state.fx.contains(where: { delayOn($0.slots) }) { applyAllFX() }
                if state.masterFX.on, delayOn(state.masterFX.slots) { applyMasterFX() }
            }
            if tickCount % 50 == 0, !loads.isEmpty { (expired, slow) = expiredLoads() }
            return tickCount % 6 == 0 ? tickHandlers : []
        }
        // Host-Ereignisse der Plugins aus dem Audio-Thread (Zuhörer, Umbau): außerhalb der Sperre, alle 10 ms
        if tickCount % 2 == 0 {
            for p in locked({ installed.flatMap { $0.flatMap { $0 } }.compactMap { $0 } }) { p.drainHostEvents() }
        }
        for l in expired {
            failLoad(l.track, l.deck, seq: l.seq, reason: String(localized: "keine Audiodaten (Cloud-Datei nicht geladen, Lesen hängt?)"), timeout: l.timeout)
        }
        for l in slow {
            let name = Self.displayName(l.track), s = Int(l.timeout.rounded()), deck = Self.deckLetter(l.deck)
            onNotice?(EngineNotice(.warning, key: "load.\(l.deck)", l.watch.fetching
                ? String(localized: "Deck \(deck) lädt noch (\(s) s ohne Daten): \(name) · Cloud-Datei wird geladen")
                : String(localized: "Deck \(deck) lädt noch (\(s) s ohne Daten): \(name)"), detail: l.track.path))
        }
        for h in handlers { h(self) }
    }
}
