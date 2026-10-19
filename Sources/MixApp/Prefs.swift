import Foundation
import MixCore
import MixEngine

/// Darstellung der Wellenform
enum WaveformStyle: String, CaseIterable, Codable, Identifiable {
    case blend = "3-Band (Mischung)", spectrum = "Spektrum (6 Bänder)", mono = "Einfarbig"
    var id: String { rawValue }
}

/// Linien des Beatgrids: fein (Haarlinien, Beats 1 Gerätepixel) oder kräftig (breiter, deckender)
enum GridLineWeight: String, CaseIterable, Codable, Identifiable {
    case fine = "fein", bold = "kräftig"
    var id: String { rawValue }
}

enum WaveformPalette: String, CaseIterable, Codable, Identifiable {
    case rgb = "Spektrum (RGB)", bone = "741 Knochen", orange = "Orange", blue = "Blau/Weiß", classic = "Klassisch"
    var id: String { rawValue }
}

/// Was die Cue-Taste am Controller macht
enum ControllerCueAction: String, CaseIterable, Codable, Identifiable {
    case fluxReverse = "Flux-Reverse (halten)", cue = "Cue (Standard)", reverse = "Reverse (halten)"
    var id: String { rawValue }
}

/// Was die Flux-Taste am Controller macht: Pad-Ebene umschalten (Hotcues 5–8, Shift + Flux = Flux-Modus) oder Flux-Modus
enum ControllerFluxButton: String, CaseIterable, Codable, Identifiable {
    case padLayer = "Pad-Ebene umschalten (Hotcues 5–8)", fluxMode = "Flux-Modus"
    var id: String { rawValue }
}

/// Shift + Flux am Controller: Grid einklopfen (wie die Werks-Belegung) oder Flux-Modus
enum ControllerShiftFlux: String, CaseIterable, Codable, Identifiable {
    case tap = "Tap (Grid einklopfen)", fluxMode = "Flux-Modus"
    var id: String { rawValue }
}

/// Flux gehalten + Pads: zweite Hotcue-Reihe oder Beatjump auf Pad 3/4
enum ControllerFluxPads: String, CaseIterable, Codable, Identifiable {
    case hotcues = "Hotcues 5–8", beatjump = "Beatjump (Pads 3/4)"
    var id: String { rawValue }
}

/// Browse-Encoder drücken (Shift + Drücken = Vorhören)
enum ControllerBrowsePush: String, CaseIterable, Codable, Identifiable {
    case bigBrowser = "Browser groß/klein", matching = "Matching an/aus"
    var id: String { rawValue }
}

enum ControllerStripMode: String, CaseIterable, Codable, Identifiable {
    case bend = "Pitch-Bend (Shift: Suchen)", seek = "Suchen (Shift: Pitch-Bend)"
    var id: String { rawValue }
}

enum PadColor: String, CaseIterable, Codable, Identifiable {
    case red = "Rot", blue = "Blau", orange = "Orange", white = "Weiß", green = "Grün", magenta = "Magenta"
    var id: String { rawValue }
    var rgb: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .red: (0x7f, 0, 0)
        case .blue: (0, 0x10, 0x7f)
        case .orange: (0x7f, 0x28, 0)
        case .white: (0x7f, 0x7f, 0x7f)
        case .green: (0, 0x7f, 0)
        case .magenta: (0x7f, 0, 0x60)
        }
    }
}

/// Shift + LOAD: laden trotz Lade-Schutz oder Instant Double vom Deck der anderen Seite
enum ControllerShiftLoad: String, CaseIterable, Codable, Identifiable {
    case force = "Laden trotz Lade-Schutz", double = "Instant Double (Deck der anderen Seite)"
    var id: String { rawValue }
}
struct ControllerPrefs: Codable, Equatable {
    var cueAction = ControllerCueAction.fluxReverse
    var fluxButton = ControllerFluxButton.padLayer
    /// Shift + Flux: Tap auf die Beats (ab 4 Taps BPM des Grids) oder Flux-Modus
    var shiftFlux = ControllerShiftFlux.tap
    /// nur im Flux-Modus: Flux antippen schaltet Flux-Modus (gehalten = Pad-Ebene)
    var fluxTapToggles = true
    var fluxBeatjumpBeats = 1.0
    var fluxPads = ControllerFluxPads.hotcues
    var stripMode = ControllerStripMode.bend
    var stripSensitivity = 1.0
    var browseFastStep = 10
    var shiftLoad = ControllerShiftLoad.force
    var browsePush = ControllerBrowsePush.bigBrowser
    var ledOn = 127
    var ledOff = 5
    /// feste Seite je Gerät: Seriennummer (sonst "loc-<USB-Position>") -> "left" / "right"
    var sides: [String: String] = [:]
    /// Lichtsequenz beim Verbinden (rot/weiß/lila, Decks der Seite, weißer Blitz)
    var startShow = true
    // alte Felder (nicht mehr benutzt, bleiben für gespeicherte Einstellungen)
    var cuePadColor = PadColor.red
    var loopPadColor = PadColor.green
    // Cue-Farben (Bildschirm + Controller-Pads)
    var colorStartCue = PadColor.red
    var colorCue = PadColor.white
    var colorLoop = PadColor.green
    var colorShortLoop = PadColor.magenta
    /// Loops bis zu so vielen Takten gelten als kurz (magenta)
    var shortLoopBars = 2.0

    /// Farbe eines Cues: Start-Cue (Load/AutoGrid), sonstige Cues, Loops, kurze Loops
    func color(for c: Cue, startMs: Double?, bpm: Double) -> PadColor {
        switch c.kind {
        case .loop:
            let bars = bpm > 0 ? c.lengthMs / 1000 / (60 / bpm) / 4 : 99
            return bars <= shortLoopBars + 0.01 ? colorShortLoop : colorLoop
        case .load, .grid:
            return colorStartCue
        default:
            if let s = startMs, abs(c.startMs - s) < 5 { return colorStartCue }
            return colorCue
        }
    }
}

/// Sichtbare Zeilen je Deck; alles an = bisheriges Bild. Neue Felder: gespeicherte Einstellungen ohne sie bekommen
/// den Standard (AppPrefs.decode legt die gespeicherten Werte über die Standardwerte)
struct DeckRows: Codable, Equatable {
    /// Kopf rechts: Zeit, BPM/Tempo, Code, Key + Phase
    var info = true
    /// Kopf, Zeile unter dem Titel: Kommentar (gedämpft) …
    var comment = true
    /// … und Tags aus Kommentar 2 als Chips
    var tags = true
    var phaseBar = true
    var overview = true
    var transport = true
    /// Hotcues mit IN / OUT / RE (Standard aus: kompakte Decks)
    var hotcues = false
    var loop = true
    var jump = false
    /// Pitch-Fader rechts (Standard aus: kompakte Decks)
    var tempo = false
    /// Groove → MIDI (Hats / Bass zum laufenden Track)
    var groove = false
    /// Vorbereiten: eine Werkzeugzeile (Play, Grid, Schnitt, Amp, Join, Split, Render), Deck dabei im EDIT-Modus
    var prepare = false

    /// Reihenfolge für Menü und Einstellungen: wie im Deck von oben nach unten, Pitch-Fader zuletzt.
    /// Grid-Werkzeuge liegen (älter) in UIPrefs, deshalb Pfade ab UIPrefs
    static let all: [(WritableKeyPath<UIPrefs, Bool>, String)] = [
        (\.deckRows.info, "Zusatzinfos (Zeit, BPM, Code, Key)"), (\.deckRows.comment, "Kommentar"),
        (\.deckRows.tags, "Tags (Kommentar 2)"), (\.deckRows.phaseBar, "Phasenbalken"), (\.deckRows.overview, "Übersicht"),
        (\.deckRows.transport, "Transport (CUE, PLAY, SYNC …)"), (\.deckRows.hotcues, "Hotcues (mit IN / OUT / RE)"),
        (\.deckRows.loop, "Loop-Größen"), (\.deckRows.jump, "Beatjump"), (\.showGridTools, "Grid-Werkzeuge"),
        (\.deckRows.groove, "Groove → MIDI"), (\.deckRows.prepare, "Vorbereiten (Grid, Schnitt, Amp, Join, Split)"),
        (\.deckRows.tempo, "Pitch-Fader"),
    ]
}

extension DeckRows {
    /// fehlende Felder -> Standard (auch in Ansichts-Profilen, die AppPrefs.decode nicht zusammenführt)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        func v(_ k: CodingKeys, _ cur: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? cur }
        info = v(.info, info); comment = v(.comment, comment); tags = v(.tags, tags); phaseBar = v(.phaseBar, phaseBar)
        overview = v(.overview, overview); transport = v(.transport, transport); hotcues = v(.hotcues, hotcues)
        loop = v(.loop, loop); jump = v(.jump, jump); tempo = v(.tempo, tempo); groove = v(.groove, groove)
        prepare = v(.prepare, prepare)
    }
}

/// Statusleiste unten: immer sichtbar, automatisch (fährt hoch, wenn die Maus am unteren Rand steht oder eine
/// Warnung kommt, liegt dann über dem Browser) oder aus
enum StatusBarMode: String, CaseIterable, Identifiable, Codable {
    case always = "Immer", auto = "Automatisch", hidden = "Aus"
    var id: String { rawValue }
}

struct UIPrefs: Codable, Equatable {
    var showMixer = true
    /// sichtbare Decks: 1 (nur A, volle Breite), 2 (A, B) oder 4; die übrigen spielen unsichtbar weiter.
    /// Ersetzt `showFourDecks` (alte Einstellungen: AppPrefs.decode)
    var deckCount = 4
    /// Deck je Platz: links oben, links unten, rechts oben, rechts unten (DeckLayout)
    var deckSlots = DeckLayout.defaultSlots
    /// genau zwei sichtbare Decks: nebeneinander (sonst übereinander)
    var twoDecksSideBySide = true
    /// Abstand zwischen den Decks und zum Fensterrand in pt (0 = keiner: die Wellenformen enden am Rand)
    var deckGap = 0.0
    var showFXUnits = true
    /// Maßstab der oberen Leiste (FX, Clock): 0,6…1,3, Griff unter der Leiste
    var topBarScale = 1.0
    var waveformSeconds = 4.0
    var waveformStyle = WaveformStyle.blend
    var waveformPalette = WaveformPalette.rgb
    /// Höhen-Betonung (0 = neutral, 1 = Standard, 3 = sehr stark) der Stile Spektrum (0…15 dB) und Einfarbig; 3-Band: im Preset
    var waveformHighBoost = 1.0
    /// alt: Variante der 3-Band-Mischung (Index A…K) – nur noch für die Umstellung auf `wavePreset`
    var blendPreset = 0
    /// Wellenform-Preset des Stils 3-Band (WavePreset.id, "" = noch nicht aus `blendPreset` / `waveformPalette` umgestellt)
    var wavePreset = ""
    var showBeatgrid = true
    /// Maus in der Wellenform greifen: aus (nur suchen), Vinyl (Scratch) oder Jog (Nudge laufend, suchen im Stopp)
    var waveGrab = WaveGrab.jog
    var showBarNumbers = true
    var dimPlayed = true
    /// Marken der anderen Decks mit Grid oben am Spielkopf (Abstand in Beats, Farbe = in Phase)
    var peerMarks = true
    var waveformHeight = 60.0
    var previewStart = 0.3
    /// Vorhören: Lautstärke (linear, 1 = Track-Pegel)
    var previewVolume = 1.0
    var browserHeight = 240.0
    var browserLayout = BrowserLayout.sideBySide
    /// Ordner-Baum ausblenden, solange die Decks zu sehen sind (Browser-Listen breiter)
    var hideTreeWithDecks = false
    var tagHighlight = true
    /// 2 oder 4 FX-Units
    var fxUnitCount = 2
    /// Marker alle 8 / 16 / 32 Takte in der Wellenform (magenta)
    var barMarkers = true
    /// "system", "de" oder "en" – wirkt nach Neustart
    var language = "system"
    /// Tag → Farbe (hex), sonst Standardfarbe aus dem Namen
    var tagColors: [String: String] = [:]
    /// Grid-Werkzeuge am Deck zeigen
    var showGridTools = false
    /// Zeilen des Decks einzeln ein-/ausblenden (Menü DECKS -> Zeilen, ⌘, -> Decks)
    var deckRows = DeckRows()
    /// History zusätzlich in den History-Ordner der Collection schreiben (dort im Archiv sichtbar)
    var historyToExternal = false
    /// Trennzeichen für Tags in Kommentar 2 (jedes Zeichen trennt; Standard Leerzeichen)
    var tagSeparators = " "
    /// Gruppen in Kommentar 2 (`K tief lang B sub …`, TagGroups): Farbe der Gruppe, Spalten in TAGS ▾
    var tagGroups = true
    /// Anzeigename je Gruppen-Marker
    var tagGroupNames = ["K": "KICK", "B": "BASS", "H": "HATS"]
    /// Farbe je Gruppen-Marker aus der Wellenform (TagWaveSource), "aus" = eigene Farbe / aus dem Namen
    var tagGroupWave = ["K": "low", "B": "lowWarm", "H": "high"]
    /// Beatgrid farbig (Phrasen/Takte/Beats) oder schlicht
    var colorfulGrid = true
    /// Linienstärke des Beatgrids
    var gridLineWeight = GridLineWeight.fine
    /// Beats je Phrase (Markierung/Farbwechsel)
    var phraseBeats = 64
    /// MUSIC FOLDERS: eigene Musik-Ordner (leer = automatisch aus der Collection)
    var musicFolders: [String] = []
    /// Metadaten-Änderungen aus dem Browser auch in die Collection-Datei schreiben (mit Sicherung davor)
    var writeCollection = false
    /// mit `writeCollection`: Cut-Kopien und Tool-Loop-Dateien (cuts.json) als neue Einträge in die Collection-Datei
    var writeCuts = true
    /// mit `writeCollection`: Preparation und eigene History-Sitzungen als Playlists unter `$ROOT/MINOS-741`
    var writePlaylists = true
    /// Browser-Vorschau (Mini-Wellenform + Grid + Cues): ganze Zeile (zweizeilig), eigene Spalte, hinter dem Titel oder aus
    var previewMode = PreviewMode.fullRow
    /// Farben der Vorschau: Spektrum (rot/grün/blau) oder wie die Wellenform
    var previewColors = PreviewColors.spectrum
    /// alt (bis 0.x): Hintergrund an/aus – nur noch für die Umstellung auf `previewFill`
    var previewBackground = true
    /// fehlende Vorschauen im Hintergrund berechnen: immer (gedrosselt, solange ein Deck spielt) / nur ohne Deck / aus
    var previewFill = PreviewFill.always
    /// Vorschau „ganze Zeile“: Schriftgröße der Textzeile (pt) und ob halbfett
    var previewTextSize = 12.0
    var previewTextBold = true
    /// Vorschau „ganze Zeile“: Deckkraft des Bandes (1 = voll, kleiner = gedämpft, Text hebt sich ab)
    var previewBandAlpha = 0.75
    /// Vorschau „ganze Zeile“: Breite des Bandes (sichtbare Breite des Browsers oder ganze Zeile)
    var previewBandSpan = PreviewBandSpan.visible
    /// Browser-Zeilen: Luft um den Text in pt (Zeilenhöhe = Schrift + Luft; 11 = wie bisher), Trennlinie unter jeder Zeile
    var browserRowPadding = 11.0
    var browserRowLines = true
    /// Live-Lesbarkeit der Liste von Hand an (⌘, -> BROWSER, Abschnitt „Live-Lesbarkeit“)
    var liveList = false
    /// Live-Lesbarkeit automatisch, solange LIVE an ist
    var liveListAuto = true
    /// Schriftgröße der Live-Liste in pt (11…18, unabhängig vom Zoom); Zeilenhöhe folgt (LiveList.rowHeight)
    var liveListTextSize = 14.0
    var liveListWeight = LiveListWeight.medium
    /// Live-Liste: Zeilen abwechselnd leicht getönt
    var liveListStripes = true
    /// Browser-Zeilen: einzeilig oder zweizeilig mit Sammelspalte „Track“ (Standard für Bereiche ohne eigene Wahl)
    var browserRows = BrowserRows.single
    /// Sammelspalte: Teile in Reihenfolge (TrackPart.rawValue, „br“ = Zeile 2)
    var trackParts: [String] = TrackParts.standard.map(\.rawValue)
    /// Detailleiste unter der Liste (Standard für Bereiche ohne eigene Wahl)
    var detailBar = DetailBarMode.auto
    /// Werte kürzen: Version im Titel als Kürzel (OM, EXT, RMX), Mitte kürzen, BPM ganzzahlig, kurzes Datum
    var shortValues = true
    /// Browser-Höhe beim Ziehen auf ganze Zeilen rasten (keine halbe Zeile unten)
    var browserSnapRows = true
    /// Cover links im Deck-Kopf
    var showDeckCover = true
    /// Breite (= Höhe) des Deck-Covers in pt, mit dem Zoom; über `deckCoverHeaderMax` eigene Spalte links neben den Zeilen
    var deckCoverSize = 32.0
    /// Höhe der Übersicht (ganze Wellenform unter dem Phasenbalken) in pt, mit dem Zoom
    var overviewHeight = 18.0
    /// Cover des gewählten Tracks unter dem Baum im Browser
    var showCoverPreview = true
    /// Last-Anzeigen rechts in der Statusleiste (DSP, Latenz, Aussetzer, Speicher, CPU)
    var showMeters = true
    /// Statusleiste: immer, automatisch (Maus am unteren Rand, Warnungen) oder aus
    var statusBar = StatusBarMode.always
    /// Collection prüfen: beim Start nach dem Laden automatisch
    var checkOnStart = false
    /// Collection prüfen: Musik-Ordner nach Dateien ohne Collection-Eintrag durchsuchen
    var checkMusicFolders = true
    /// TIDAL: Client-ID der eigenen App (öffentlich, kein Geheimnis); ⌘, → Browser
    var tidalClientID = ""
    /// TIDAL: Name der Playlist für MISSING (%Y %y %m %d)
    var tidalPlaylistPattern = TidalMatch.defaultPattern
    /// Zoom des Hauptfensters (1 = 100 %, ZoomSteps)
    var zoom = 1.0
    /// eigene Analyse: BPM-Bereich genau eine Oktave, Untergrenze (Obergrenze = 2 ×)
    var analysisBpmLow = 100.0
    /// Rip-Prüfung (Stille, fremder Anfang / fremdes Ende, Grid-Verdacht) mit jeder Analyse
    var ripWithAnalysis = true
    /// Rip-Befund beim Laden als markierten Bereich setzen (nichts wird geschnitten)
    var ripMarkOnLoad = true
    /// Audio-Edit: NORM / AMP vorschlagen, wenn die Spitze mehr als so viele dB unter 0 dBFS liegt
    var audioEditHeadroom = 3.0
    /// Audio-Edit: Raster beim Markieren beim Eintritt an (in der Werkzeugzeile per RASTER umschalten); Standard aus
    /// Raster beim Öffnen (neuer Schlüssel: Standard an, der alte stand bei allen auf aus)
    var audioEditGrid = true
    /// Rasterweite in Beats (AudioEditView.snapSteps)
    var audioEditSnapBeats = 1.0
    /// DAW-Brücke: Pakete des Remote Scripts auf 127.0.0.1 empfangen (UDP)
    var dawBridge = true
    var dawBridgePort = 7411
    /// Browser: Key-Spalte nach Harmonie zum Master färben (◆ gleich, ▲▼ ±1, ◇ Relativ)
    var harmonyColors = true
    /// Browser-Filter „passt zum Master“ (◆ PASST, ⌘, -> BROWSER)
    var match = MatchRule()
    /// Bezug für ◆ PASST: Decks (0–3), leer = AUTO (spielender Master, sonst Fokus-Deck); mehrere = muss zu allen passen
    var matchDecks: [Int] = []
    /// gespielte Tracks (History dieser Sitzung bzw. seit dem letzten Reset) im Browser dimmen
    var dimPlayedTracks = true
    /// gespielte Tracks aus Collection, Playlists, Smartlists und Ordnern ausblenden (◆ UNGESPIELT; History, RUNNING
    /// und Preparation zeigen sie weiter)
    var hidePlayedTracks = false
    /// Played-Status beim Start der App zurücksetzen (wie ⌥⌘P), Standard an
    var resetPlayedOnStart = true
    /// Zwei-Mac-Modus (bleibt auf dem Mac)
    var pair = PairSetup()
    /// Collection-Datei, die die Einrichtung gewählt hat (leer = automatisch gesucht); bleibt auf dem Mac
    var collectionPath = ""
    /// Vollständige Absturzberichte (ohne Geräte-Kennungen) automatisch in den Ordner unten schreiben; Standard aus
    var crashReports = false
    /// Ordner für die Absturzberichte (bleibt auf dem Mac, leer = nichts wird geschrieben)
    var crashReportFolder = ""
    /// Nach einem Absturz fragen: Sheet mit dem bereinigten Bericht beim nächsten Start (Standard an)
    var askAfterCrash = true
    /// Bei LIVE die VST3-Plugins überbrücken (trocken, sie rechnen nicht; Absturzschutz, da sie im Prozess laufen). Standard an
    var liveBypassVST3 = true
    /// Zeitpunkt des neuesten kopierten Absturzberichts (Sekunden seit 1970, 0 = noch keiner)
    var crashLastCopied = 0.0
    /// Zeitpunkt des neuesten Berichts, zu dem gefragt wurde (Sekunden seit 1970, 0 = noch keiner)
    var crashLastPrompted = 0.0
    /// Schneiden (Bereich entfernen / auf Bereich kürzen): Ergebnis gleich ins selbe Deck laden (Lade-Schutz gilt)
    var cutLoadsResult = false
    /// EDIT-Modus: Raster beim Markieren (Ziehen in der Wellenform), ⌥ = frei
    var editSnap = EditSnap.bar
    /// Tool-Loops: Zielordner ("" = neben dem Original)
    var toolLoopFolder = ""
    /// Vorbereiten AMP: über 0 dBFS anheben erlaubt (Spitzen werden hart begrenzt), Standard aus
    var prepAllowClipping = false
    /// Vorbereiten JOIN: Tempo der zweiten Datei angleichen, wenn es bis ±0,5 % gleich ist
    var prepJoinMatchTempo = true
    /// Ausgabe der gerenderten Dateien (RENDER, Schnitt, JOIN, SPLIT, Tool-Loop): Format, Bit, Abtastrate, Dither, Name
    var export = ExportOptions()

    /// Update-Kanal: neuester Build (Standard), stabile Versionen, eigener Ordner, aus (Updater.swift)
    var updateChannel = UpdateChannel.latestBuild
    /// Update-Ordner für den Kanal „Eigener Ordner“ (latest.json + DMG, scripts/make-dmg.sh --publish)
    var updateFolder = ""
    /// Build, den ein Zurückwechseln verlassen hat: nicht automatisch installieren (manuell „Installieren“ bleibt möglich)
    var updateSkipBuild = ""
    /// Erstellungsdatum dieses Builds (MINOSBuildDate): ein späterer Build hebt das Überspringen auf
    var updateSkipDate = ""
    /// Updates automatisch installieren, sobald nichts spielt, LIVE aus ist und 2 min keine Eingabe kam; Standard aus
    var autoUpdate = false

    /// Ansichts-Profile (Menü Darstellung -> Profil, ⌘, -> Anzeige); fehlt das Feld, legt AppPrefs.decode drei an
    var layoutProfiles: [LayoutProfile] = []
    /// zuletzt angewendetes Profil (LayoutProfile.id, "" = keins)
    var activeLayoutProfile = ""
    /// Reihenfolge der Bereiche in ⌘, (Titel-Schlüssel, per Ziehen in der Seitenleiste; leer = Standard)
    var settingsTabOrder: [String] = []
    /// Favoriten der Einstellungen (Anker-IDs in Markier-Reihenfolge); unbekannte IDs werden ignoriert
    var settingsFavorites: [String] = []
    /// erster Start: Einstellungen öffnen auf ALLGEMEIN, danach der zuletzt gezeigte Bereich
    var settingsOpened = false
    var settingsLastTab = ""

    /// alt: 2 / 4 Decks (Kürzel ⌥⌘4, Selbsttest); von 1 Deck aus -> 4
    var showFourDecks: Bool {
        get { deckCount >= 4 }
        set { deckCount = newValue ? 4 : 2 }
    }

    static let deckCoverRange = 32.0...200.0
    static let overviewHeightRange = 12.0...120.0
    /// bis zu dieser Breite sitzt das Cover im Kopf, darüber in einer eigenen Spalte über mehrere Zeilen
    static let deckCoverHeaderMax = 40.0

    var deckCoverInHeader: Bool { showDeckCover && deckCoverSize <= Self.deckCoverHeaderMax }
    var deckCoverColumn: Bool { showDeckCover && deckCoverSize > Self.deckCoverHeaderMax }

    /// kompakte Decks: ohne Pitch-Fader, Hotcues und Grid-Werkzeuge (mehr Platz für Wellenform und Beatgrid)
    var compactDecks: Bool {
        get { !deckRows.tempo && !deckRows.hotcues && !showGridTools }
        set { deckRows.tempo = !newValue; deckRows.hotcues = !newValue; showGridTools = !newValue }
    }

    /// alle Zeilen aus DeckRows.all an (ohne Vorbereiten: die Zeile doppelt Transport, Grid und Schnitt)
    mutating func showAllDeckRows() { for (k, _) in DeckRows.all where k != \UIPrefs.deckRows.prepare { self[keyPath: k] = true } }

    /// EDIT-Modus je Deck A–D (Schnitt + Grid statt Loop / Beatjump), Standard aus
    var editDecks = [false, false, false, false]

    func editing(_ d: Int) -> Bool { editDecks.indices.contains(d) && editDecks[d] }
    mutating func setEditing(_ d: Int, _ on: Bool) {
        guard d >= 0, d < 4 else { return }
        while editDecks.count < 4 { editDecks.append(false) }
        editDecks[d] = on
    }
}

/// Alle Einstellungen der App, als JSON in UserDefaults gespeichert.
struct AppPrefs: Codable, Equatable {
    var engine = EnginePrefs()
    var ui = UIPrefs()
    var controller = ControllerPrefs()
    /// Cloud-Library: lokal halten, Downloads (⌘, -> CLOUD)
    var cloud = CloudPrefs()
    /// Groove → MIDI (⌘, -> DECKS)
    var groove = GroovePrefs()
    /// MIDI-Clock zum Mischpult (⌘, -> AUDIO)
    var midiClock = MIDIClockPrefs()
    /// Aufnahme (⌘, -> AUDIO)
    var record = RecordPrefs()
    /// Auto-Mix (⌘, -> MIXER & FX)
    var autoMix = AutoMixPrefs()
    /// eigene Tastenkürzel: Aktion-ID -> Kombination als Text ("" = frei), sonst Standard (ShortcutID.defaultCombo)
    var shortcuts: [String: String] = [:]
    /// Spaltenanordnung der Track-Tabellen: Schlüssel `columns.<Bereich>` (`.2` = zweizeilig); alt ohne Eintrag = Standard
    var columns: [String: ColumnLayout.State] = [:]

    var keys: ShortcutMap {
        get { ShortcutMap(overrides: shortcuts) }
        set { shortcuts = newValue.overrides }
    }

    static let key = "prefs.v1"

    /// Lädt gespeicherte Einstellungen; fehlende (neue) Felder bekommen ihren Standardwert,
    /// statt dass alles auf Standard zurückfällt.
    static func load() -> AppPrefs {
        var p = loadSaved()
        // FDN-Hall: neue Standard-Helligkeit 0,6; wer den alten Standard 0,4 nie verändert hat, bekommt den neuen (einmalig)
        let d = E2E.defaults
        if !Session.isSelfTest, !d.bool(forKey: "migrated.reverb-fdn") {
            if d.data(forKey: key) != nil, p.engine.reverbBrightness == 0.4 { p.engine.reverbBrightness = EnginePrefs().reverbBrightness; p.save() }
            d.set(true, forKey: "migrated.reverb-fdn")
        }
        // Browser-Vorschau: alter Standard „eigene Spalte“ -> neuer Standard „ganze Zeile“ (einmalig)
        if !Session.isSelfTest, !d.bool(forKey: "migrated.preview-row") {
            if d.data(forKey: key) != nil, p.ui.previewMode == .column { p.ui.previewMode = .fullRow; p.save() }
            d.set(true, forKey: "migrated.preview-row")
        }
        // Hintergrund-Vorschauen: wer den alten Schalter ausgeschaltet hatte, bekommt „aus“ (einmalig)
        if !Session.isSelfTest, !d.bool(forKey: "migrated.preview-fill") {
            if d.data(forKey: key) != nil, !p.ui.previewBackground { p.ui.previewFill = .off; p.save() }
            d.set(true, forKey: "migrated.preview-fill")
        }
        // Profil „Vorbereiten“ zu schon gespeicherten Profilen (einmalig; erster Start: LayoutProfile.defaults)
        if !Session.isSelfTest, !d.bool(forKey: "migrated.prepare-profile") {
            if d.data(forKey: key) != nil, !p.ui.layoutProfiles.contains(where: { $0.id == LayoutProfile.prepareID }) {
                p.ui.layoutProfiles.append(LayoutProfile.prepare(from: p.ui))
                p.save()
            }
            d.set(true, forKey: "migrated.prepare-profile")
        }
        // Einstellungen: wer schon Einstellungen hat, öffnet nicht ALLGEMEIN, sondern den zuletzt gezeigten Bereich (einmalig)
        if !Session.isSelfTest, !d.bool(forKey: "migrated.settings-opened") {
            if d.data(forKey: key) != nil, !p.ui.settingsOpened { p.ui.settingsOpened = true; p.save() }
            d.set(true, forKey: "migrated.settings-opened")
        }
        return p
    }

    private static func loadSaved() -> AppPrefs {
        guard let data = E2E.defaults.data(forKey: key) else {
            var p = AppPrefs()
            p.ui.layoutProfiles = LayoutProfile.defaults(from: p.ui)
            return p
        }
        return decode(data)
    }

    /// gespeichertes JSON über die Standardwerte legen: fehlende (neue) Felder bekommen ihren Standard
    static func decode(_ data: Data) -> AppPrefs {
        guard var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(AppPrefs()),
              let defaults = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return AppPrefs() }
        if let old = saved["x1"], saved["controller"] == nil { saved["controller"] = old }   // alter Schlüssel
        var ui = saved["ui"] as? [String: Any] ?? [:]
        // alt: showFourDecks -> deckCount
        if ui["deckCount"] == nil, let four = ui["showFourDecks"] as? Bool { ui["deckCount"] = four ? 4 : 2; saved["ui"] = ui }
        let hadProfiles = ui["layoutProfiles"] != nil
        var p = merged(saved, over: defaults)
        // gemerkte FX-Belegungen der früheren Gruppe (bis 2026-10) -> Rack-Kennungen
        p.engine.fxMappings = FXMigration.mappings(p.engine.fxMappings)
        // noch keine Profile gespeichert -> „Default Setup“, „Musik suchen“, „Vorbereiten“ aus der gespeicherten Ansicht
        if !hadProfiles { p.ui.layoutProfiles = LayoutProfile.defaults(from: p.ui) }
        return p
    }

    private static func merged(_ saved: [String: Any], over defaults: [String: Any]) -> AppPrefs {
        func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
            var r = base
            for (k, v) in over {
                // leeres Objekt im Standard = freie Zuordnung (tagColors, shortcuts) -> gespeicherten Inhalt ganz übernehmen
                if let b = base[k] as? [String: Any], !b.isEmpty, let o = v as? [String: Any] { r[k] = merge(b, o) } else if base[k] != nil { r[k] = v }
            }
            return r
        }
        if let merged = try? JSONSerialization.data(withJSONObject: merge(defaults, saved)),
           let p = try? JSONDecoder().decode(AppPrefs.self, from: merged) { return p }
        // einzelner Wert passt nicht mehr (z. B. nach Update) → Wert für Wert übernehmen, Rest bleibt erhalten
        func leaves(_ d: [String: Any], _ path: [String] = []) -> [([String], Any)] {
            d.flatMap { k, v -> [([String], Any)] in
                if let o = v as? [String: Any] { return leaves(o, path + [k]) }
                return [(path + [k], v)]
            }
        }
        func setting(_ d: [String: Any], _ path: [String], _ v: Any) -> [String: Any] {
            var r = d
            guard let k = path.first else { return r }
            if path.count == 1 { if r[k] != nil { r[k] = v } } else if let sub = r[k] as? [String: Any] { r[k] = setting(sub, Array(path.dropFirst()), v) }
            return r
        }
        var good = defaults
        for (path, v) in leaves(saved) {
            let trial = setting(good, path, v)
            if let data = try? JSONSerialization.data(withJSONObject: trial), (try? JSONDecoder().decode(AppPrefs.self, from: data)) != nil {
                good = trial
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: good),
              let p = try? JSONDecoder().decode(AppPrefs.self, from: data) else { return AppPrefs() }
        return p
    }

    func save() {
        guard !Session.isSelfTest else { return }   // Selbsttest darf Christians Einstellungen nicht überschreiben
        if let data = try? JSONEncoder().encode(self) { E2E.defaults.set(data, forKey: Self.key) }
        SettingsFile.scheduleExport()
    }
}

/// Groove → MIDI: Quelle, Kanäle, Bass-Oktave, Auswahl der Deck-Zeile
struct GroovePrefs: Codable, Equatable {
    /// Name der virtuellen MIDI-Quelle
    var sourceName = "MINOS-741 Groove"
    /// Kanäle 1–16
    var bassChannel = 1
    var drumChannel = 10
    /// Oktave des Grundtons (C3 = 60): 1 -> 36–47
    var bassOctave = 1
    /// Zeitstempel verschieben (ms, positiv = später)
    var offsetMs = 0.0
    /// Takte ab der nächsten Eins (ohne Loop)
    var bars = 2
    var instrument = GrooveInstrument.both
    var style = GrooveStyle.off
}
