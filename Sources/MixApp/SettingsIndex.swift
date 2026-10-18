import Foundation
import MixCore

/// eine auffindbare Zeile der Einstellungen. Texte sind Lokalisierungsschlüssel (deutsch), Englisch kommt aus der
/// Strings-Tabelle. `anchor` steht als `.settingsAnchor(…)` genau einmal im Quelltext; mehrere Einträge dürfen sich
/// einen Anker teilen (Controller-Block, Zeilen je Deck). `alt`: Anker, wenn die Zeile gerade ausgeblendet ist
struct SettingsEntry: Sendable, Hashable {
    let tab: String
    let section: String
    let anchor: String
    let label: String
    var hint: String?
    var keywords: [String] = []
    var alt: String?
    /// im einklappbaren Abschnitt ERWEITERT des Bereichs (Sprung klappt ihn auf)
    var advanced: Bool { SettingsIndex.advancedSections.contains(tab + "|" + section) }
}

/// Index aller Einstellungen für die Suche (⌘, -> Suchfeld). Statisch statt Introspektion der Views; ein Unit-Test
/// gleicht ihn mit den Ankern im Quelltext ab
enum SettingsIndex {
    static let entries: [SettingsEntry] = rows + shortcuts

    /// alle Anker (Favoriten: unbekannte IDs werden ignoriert)
    static let anchors: Set<String> = Set(entries.map(\.anchor))

    /// Abschnitte im einklappbaren Bereich ERWEITERT, als „BEREICH|Abschnitt“ (Schlüssel gleich dem Quelltext)
    static let advancedSections: Set<String> = [
        "AUDIO|Puffer-Test", "AUDIO|Laden & Cache", "AUDIO|Rechenkern",
        "DECKS|Loop-Snap", "DECKS|Phrasen-Anker", "DECKS|EDIT-Modus & Tool-Loops", "DECKS|Vorbereiten", "DECKS|Ausgabe (Render)",
        "MIXER & FX|FX-Belegung (D/W · Regler · Tasten)", "MIXER & FX|Gemerkte Belegungen", "MIXER & FX|Gemerkte Racks",
        "ANZEIGE|Mischung (3-Band)",
        "BROWSER|Browser-Vorschau", "BROWSER|Tag-Farben", "BROWSER|Analyse",
        "CONTROLLER & TASTEN|LED-Helligkeit", "CONTROLLER & TASTEN|Feste Belegung (Standard)",
        "LIVE & SYNC|Groove → MIDI",
        "CLOUD|Dauerhaft offline",
    ]

    /// Anker einer Tastatur-Zeile
    static func keyAnchor(_ a: ShortcutID) -> String { "keys." + a.rawValue }

    /// Tastatur: ein Eintrag je Aktion, Titel in der aktuellen Sprache, Stichwörter aus der ID (englisch)
    static var shortcuts: [SettingsEntry] {
        ShortcutID.allCases.map { a in
            SettingsEntry(tab: "CONTROLLER & TASTEN", section: a.group.title, anchor: keyAnchor(a), label: a.title,
                          keywords: a.rawValue.split(separator: ".").map(String.init) + ["kürzel", "shortcut"])
        }
    }

    private static func e(_ tab: String, _ section: String, _ anchor: String, _ label: String, hint: String? = nil,
                          kw: String = "", alt: String? = nil) -> SettingsEntry {
        SettingsEntry(tab: tab, section: section, anchor: anchor, label: label, hint: hint,
                      keywords: kw.split(separator: " ").map(String.init), alt: alt)
    }

    static let rows: [SettingsEntry] = general + audio + decks + mixerFX + plugins + browser + display + controller + tags + cloud + keys

    private static let general: [SettingsEntry] = [
        e("ALLGEMEIN", "Einrichtung", "general.setup", "Einrichtungs-Ablauf", hint: "Zeigt die Einrichtung noch einmal: Sammlung, Ausgabegerät, Controller. Nichts wird gelöscht.", kw: "setup erststart einrichtung"),
        e("ALLGEMEIN", "Daten", "general.datafolder", "Datenordner", hint: "Ordner MINOS-741 neben der Collection-Datei: settings.plist, Analysen, Edits, Cuts, Playlists, History. Zieht mit der Collection um.", kw: "daten ordner folder collection settings"),
        e("ALLGEMEIN", "Daten", "general.settingsfile", "Einstellungsdatei", kw: "settings plist datei"),
    ]

    private static let audio: [SettingsEntry] = {
        let t = "AUDIO"
        return [
            e(t, "Ausgabegerät", "audio.device", "Gerät", kw: "interface soundkarte output device"),
            e(t, "Ausgabegerät", "audio.channels", "Kanäle", kw: "channels"),
            e(t, "Ausgabegerät", "audio.samplerate", "Samplerate",
              hint: "Eine neue Samplerate gilt am Gerät sofort, MINOS-741 rechnet ab dem nächsten Start damit.", kw: "khz hz"),
            e(t, "Ausgabegerät", "audio.buffer", "Puffer (Latenz)", kw: "frames ms"),
            e(t, "Puffer-Test", "audio.buffertest", "PUFFER TESTEN", hint: BufferTestSettings.hint,
              kw: "buffer test latency latenz frames empfehlung recommendation xrun aussetzer"),
            e(t, "Mischpult", "audio.mixerprofile", "Erkannt", kw: "mixer profil pult djm desk midi"),
            e(t, "MIDI-Clock", "audio.midiclock", "MIDI-Clock an MIDI-Ausgang senden",
              hint: "24 Takte je Viertel aus der Master-Clock an den gewählten MIDI-Ausgang, Start und Stop folgen dem Transport. Wie das empfangende Gerät darauf reagiert, ist nicht geprüft.", kw: "midi clock tempo takt ausgang"),
            e(t, "Ausgabegerät", "audio.reconnect", "Neu verbinden",
              hint: "startet die Ausgabe neu, z. B. wenn das Interface nach einem USB-Aussetzer stumm bleibt", kw: "reconnect usb"),
            e(t, "Mixer", "audio.mixermode", "Modus", kw: "mixer intern extern mischpult internal external"),
            e(t, "Ausgang (Master)", "audio.masterpair", "Master", kw: "kanalpaar ausgang output", alt: "audio.mixermode"),
            e(t, "Deck → Kanal", "audio.deckpairs", "Standard: A 1/2 · B 3/4 · C 5/6 · D 7/8",
              hint: "Am Mischpult die Kanal-Eingänge auf USB stellen. EQ, Fader, Crossfader und Kopfhörer-Cue macht dann das Pult; Filter, FX und Gain bleiben in MINOS-741.",
              kw: "kanalpaar extern", alt: "audio.mixermode"),
            e(t, "Vorhören", "audio.preview.pair", "Vorhören auf Kanalpaar", kw: "preview kopfhörer"),
            e(t, "Vorhören", "audio.preview.now", "Vorhören jetzt auf", kw: "preview"),
            e(t, "Vorhören", "audio.preview.volume", "Lautstärke Vorhören",
              hint: "läuft auf dem gewählten paar mit, unabhängig von main. ein paar fürs kopfhörer-signal des interfaces -> vorhören nur dort.",
              kw: "preview pegel"),
            e(t, "Aufnahme", "audio.record.source", "Quelle",
              hint: "rec in der oberen leiste oder im mixer (zeile master): klick = start, noch mal = stopp. interner master = das main-paar nach fadern, crossfader, master-fx, main und begrenzung, ohne metronom und vorhören. eingang vom pult = das gewählte eingangspaar der soundkarte (pult-summe auf usb legen). datei: jjjj-mm-tt hh.mm set.m4a mit der rate des kerns bzw. des eingangs, daneben .txt und .cue mit den tracks aus der history (alle 60 s und beim stopp). gerät weg: datei wird geschlossen, keine automatische fortsetzung.",
              kw: "rec recording aufnehmen"),
            e(t, "Aufnahme", "audio.record.inputdevice", "Eingangsgerät", kw: "rec recording", alt: "audio.record.source"),
            e(t, "Aufnahme", "audio.record.inputpair", "Eingangspaar", kw: "rec recording", alt: "audio.record.source"),
            e(t, "Aufnahme", "audio.record.inputlevel", "Eingangspegel anzeigen", kw: "rec recording", alt: "audio.record.source"),
            e(t, "Aufnahme", "audio.record.format", "Format", kw: "rec recording wav aiff alac"),
            e(t, "Aufnahme", "audio.record.folder", "Ordner", kw: "rec recording"),
            e(t, "Laden & Cache", "audio.load.decoder", "Dekodieren",
              hint: "datei-dienst: dateien werden in einem eigenen prozess gelesen und dekodiert. hängt eine cloud-datei, lädt das deck weiter (hinweis), abgebrochen wird erst nach der zweiten grenze. ohne datei-dienst: abbruch schon nach der ersten. cache: ~/Library/Application Support/MINOS-741/cache, älteste zuerst gelöscht, tracks in den decks bleiben.",
              kw: "datei-dienst"),
            e(t, "Laden & Cache", "audio.load.notice", "Hinweis nach (keine Audiodaten)", kw: "timeout"),
            e(t, "Laden & Cache", "audio.load.abort", "Laden abbrechen nach (keine Audiodaten)", kw: "timeout"),
            e(t, "Laden & Cache", "audio.load.cache", "Cache dekodierter Tracks", kw: "gb speicher"),
            e(t, "Rechenkern", "audio.parallel", "Decks parallel rechnen",
              hint: "Deck A im Audio-Thread, B–D auf eigenen Echtzeit-Threads neben dem Gerät (gleicher Klang, Summe danach). Zum Vergleich im Lasttest; bei kleinen Puffern mit 4 Decks Keylock + FX niedrigere Spitzenlast je Kern.",
              kw: "threads cpu kern"),
        ]
    }()

    private static let display: [SettingsEntry] = {
        let t = "ANZEIGE", w = "Wellenform"
        return [
            e("ALLGEMEIN", "Sprache", "display.language", "Sprache (wirkt nach Neustart)", kw: "deutsch english"),
            e("ALLGEMEIN", "Zoom", "display.zoom", "Hauptfenster (⌘+ / ⌘− / ⌘0)", kw: "zoom größe skalierung"),
            e("ALLGEMEIN", "Updates", "display.update.channel", "Update-Kanal",
              hint: "neuester build: jeder build (rollendes release). stabile versionen: nur vX.Y.Z-releases. eigener ordner: latest.json und dmg aus einem ordner. aus: keine updates",
              kw: "update aktualisierung version kanal channel github release neuester build stabil"),
            e("ALLGEMEIN", "Updates", "display.update.folder", "Ordner", kw: "update aktualisierung drive ordner latest dmg"),
            e("ALLGEMEIN", "Updates", "display.update.auto", "Updates automatisch installieren",
              hint: "nur wenn kein deck spielt, live aus ist und 2 min keine eingabe kam", kw: "update automatisch installieren auto-update"),
            e("ALLGEMEIN", "Updates", "display.update.check", "Jetzt prüfen", kw: "update prüfen version wiederherstellen rollback"),
            e(t, "Layout", "display.deckcount", "Decks anzeigen", kw: "4 decks"),
            e(t, "Layout", "display.deckslots", "Links oben", kw: "deck anordnung position platz links rechts oben unten a b c d"),
            e(t, "Layout", "display.twodecks", "Zwei Decks", kw: "nebeneinander übereinander zwei decks"),
            e(t, "Layout", "display.deckgap", "Abstand zwischen Decks (pt)",
              hint: "0 = die Wellenformen enden an den Deck-Rändern und am Fensterrand, nur die Rahmenlinie dazwischen."),
            e(t, "Layout", "display.browserlayout", "Browser-Anordnung"),
            e(t, "Layout", "display.hidetree", "Ordner-Baum ausblenden, solange Decks sichtbar sind"),
            e(t, "Profile", "display.profiles", "Aktuelle Ansicht speichern …",
              hint: "profil = decks (1 / 2 / 4), mixer, fx-units, zeilen je deck, browser (anordnung, höhe, baum, groß), statusleiste, last-anzeigen, wellenform-mindesthöhe, cover und cover-breite, übersicht-höhe, vorschau. nicht: audio, controller, wellenform-stil und farben, tags, tastatur. umschalten: profil-menü links in der werkzeugleiste, menü darstellung -> profil, die ersten vier per taste (⌘, -> tastatur), nächstes ⌃⌥⇥. ◆ = aktiv, * = ansicht seitdem geändert -> aktualisieren übernimmt sie.",
              kw: "profile ansichts-profil layout"),
            e(t, "Statusleiste", "display.statusbar", "Anzeigen",
              hint: "automatisch: die leiste fährt hoch, wenn die maus am unteren fensterrand steht oder eine warnung kommt, und liegt dann über dem browser. aus: keine leiste, auch keine meldungen. auch im menü darstellung.",
              kw: "statusleiste status bar"),
            e(t, "Statusleiste", "display.meters", "Last-Anzeigen (DSP, Latenz, Aussetzer, Speicher, CPU)",
              hint: "dsp = rechenzeit des audio-blocks ÷ blockdauer, rot ab 70 %. aussetzer: blöcke über dem budget plus überlast-meldungen des geräts, klick setzt zurück. meldungen: klick zeigt die letzten 50."),
            e(t, w, "display.wave.style", "Stil", kw: "wellenform waveform spektrum mono 3-band"),
            e(t, w, "display.wave.palette", "Farben", kw: "wellenform waveform", alt: "display.wave.style"),
            e(t, w, "display.wave.highboost", "Höhen-Betonung", kw: "wellenform spektrum", alt: "display.wave.style"),
            e(t, w, "display.wave.seconds", "Sichtbare Sekunden je Seite (Zoom)", kw: "wellenform waveform zoom"),
            e(t, w, "display.wave.height", "Mindesthöhe (pt, wächst mit dem Fenster)", kw: "wellenform waveform"),
            e(t, w, "display.wave.dim", "Gespielten Teil abdunkeln", kw: "wellenform waveform"),
            e(t, w, "display.wave.peers", "Andere Decks in der Wellenform",
              hint: "dreieck mit buchstabe oben am roten strich: wo das andere deck (mit grid) gegenüber diesem track läuft. lila = in phase, grau = steht. am rand: pfeil mit abstand.",
              kw: "wellenform waveform phase code sync"),
        ] + wave + [
            e(t, "Beatgrid", "display.grid.show", "Beatgrid anzeigen", kw: "grid"),
            e(t, "Beatgrid", "display.grid.colorful", "Farbig (Phrasen, Takte, Beats)", kw: "grid"),
            e(t, "Beatgrid", "display.grid.phrase", "Phrase", kw: "grid"),
            e(t, "Beatgrid", "display.grid.barnumbers", "Taktnummern", kw: "grid"),
            e(t, "Beatgrid", "display.grid.markers", "Marker alle 8 / 16 / 32 Takte (magenta)", kw: "grid"),
            e(t, "Beatgrid", "display.grid.lines", "Linien", kw: "grid"),
            e("CONTROLLER & TASTEN", "Cue-Farben (Bildschirm und Controller-Pads)", "display.cue.start", "Start-Cue (Load / AutoGrid)", kw: "farbe pads"),
            e("CONTROLLER & TASTEN", "Cue-Farben (Bildschirm und Controller-Pads)", "display.cue.cue", "Cue", kw: "farbe pads"),
            e("CONTROLLER & TASTEN", "Cue-Farben (Bildschirm und Controller-Pads)", "display.cue.loop", "Loop", kw: "farbe pads"),
            e("CONTROLLER & TASTEN", "Cue-Farben (Bildschirm und Controller-Pads)", "display.cue.shortloop", "Kurzer Loop", kw: "farbe pads"),
            e("CONTROLLER & TASTEN", "Cue-Farben (Bildschirm und Controller-Pads)", "display.cue.shortbars", "Kurz = bis", kw: "farbe pads"),
        ]
    }()

    /// Stil 3-Band (Mischung): Preset und seine Werte, sonst ausgeblendet -> Stil
    private static let wave: [SettingsEntry] = {
        let t = "ANZEIGE", w = "Wellenform", s = "display.wave.style", m3 = "Mischung (3-Band)"
        func f(_ anchor: String, _ label: String, hint: String? = nil, kw: String = "") -> SettingsEntry {
            e(t, anchor == "display.wave.preset" ? w : m3, anchor, label, hint: hint, kw: "preset 3-band " + kw, alt: s)
        }
        return [
            f("display.wave.preset", "Preset", hint: "eingebaut: die erste änderung legt eine eigene kopie an („… kopie“) und wählt sie. eigene presets: wave-presets.json im minos-741-ordner."),
            f("display.wave.low", "Trennfrequenz Tief", hint: "tief = tiefpass, mitte = bandpass, hoch = hochpass. auto = geometrisches mittel aus tief und hoch. änderungen rechnen geladene tracks im hintergrund neu.", kw: "crossover hz"),
            f("display.wave.mid", "Trennfrequenz Mitte", kw: "crossover hz"),
            f("display.wave.high", "Trennfrequenz Hoch", kw: "crossover hz"),
            f("display.wave.attack.low", "Anstieg Tief", kw: "attack"), f("display.wave.release.low", "Abfall Tief", kw: "release"),
            f("display.wave.attack.mid", "Anstieg Mitte", kw: "attack"), f("display.wave.release.mid", "Abfall Mitte", kw: "release"),
            f("display.wave.attack.high", "Anstieg Hoch", kw: "attack"), f("display.wave.release.high", "Abfall Hoch", kw: "release"),
            f("display.wave.weight.low", "Analyse-Gewicht Tief"), f("display.wave.weight.mid", "Analyse-Gewicht Mitte"),
            f("display.wave.weight.high", "Analyse-Gewicht Hoch"),
            f("display.wave.direct", "Bandanteile direkt als Rot / Grün / Blau", kw: "rgb farbe"),
            f("display.wave.color.low", "Farbe Tief"), f("display.wave.color.mid", "Farbe Mitte"), f("display.wave.color.high", "Farbe Hoch"),
            f("display.wave.color.highopen", "Gehaltene Höhen (offene Hats)", kw: "farbe"),
            f("display.wave.color.lowwarm", "Gehaltene Tiefen (Bassline)", kw: "farbe"),
            f("display.wave.gain.low", "Lautstärke Tief"), f("display.wave.gain.mid", "Lautstärke Mitte"),
            f("display.wave.gain.high", "Lautstärke Hoch"),
            f("display.wave.preset.highboost", "Höhen-Betonung"),
            f("display.wave.base", "Energie-Anteil (base)"), f("display.wave.fade", "Übergänge (fade)"),
            f("display.wave.stack", "Stapel-Kurve"), f("display.wave.saturation", "Sättigung (RGB)"),
            f("display.wave.warmth", "Orange gehaltener Tiefen", kw: "farbe"),
            f("display.wave.openness", "Hellblau gehaltener Höhen",
              hint: "rot / grün / blau direkt: bandanteile als farbkanäle (kick-anschlag rot, mitten grün, kurze höhen blau), sonst die drei farben. lautstärke = gewicht des bands in farbe und stapelhöhe. energie-anteil 1 = nur mischung, 0 = nur stapel (stärkstes band innen). sättigung nur bei rot / grün / blau direkt.",
              kw: "farbe"),
        ]
    }()

    private static let decks: [SettingsEntry] = {
        let t = "DECKS", l = "Loops & Beatjump", ed = "EDIT-Modus & Tool-Loops", g = "Groove → MIDI"
        return [
            e(t, "Abspielen", "decks.snap", "Snap (Cues und Loop-Punkte rasten auf den Beat)"),
            e(t, "Abspielen", "decks.quant", "Quant (Sprünge halten die Beat-Phase)", kw: "quantize"),
            e(t, "Abspielen", "decks.hotcuephase", "Hotcue-Sprung hält die Beat-Phase"),
            e(t, "Abspielen", "decks.loadpos", "Beim Laden springen zu", kw: "load cue"),
            e(t, "Abspielen", "decks.endwarning", "Track-Ende-Warnung (s, 0 = aus)", kw: "end warning"),
            e(t, "Abspielen", "decks.loadprotect", "Lade-Schutz bei laufendem Deck",
              hint: "spielt das deck, wird nicht geladen (doppelklick, taste, controller-load) -> hinweis in der statusleiste. trotzdem laden: ⌥-doppelklick, shift + load, taste „auswahl ins fokus-deck laden (auch wenn es spielt)“.",
              kw: "load lock"),
            e("LIVE & SYNC", "Zwei Macs", "decks.pair", "Zwei-Mac-Modus", kw: "zwei-mac pair zweiter mac bildschirm ethernet usb thunderbolt"),
            e("LIVE & SYNC", "Zwei Macs", "decks.pairwrites", "Dieser Mac schreibt (Collection, History)", kw: "zwei-mac schreiben collection history"),
            e("LIVE & SYNC", "Zwei Macs", "decks.pairdecks", "Decks dieses Macs (höchstens 2)", kw: "zwei-mac decks a b c d"),
            e("LIVE & SYNC", "Zwei Macs", "decks.pairdebug", "Fernzugriff zum Analysieren erlauben", kw: "zwei-mac debug analyse remote fernzugriff"),
            e(t, "Tempo & Sync", "decks.keylock", "Keylock beim ersten Laden an", kw: "master tempo"),
            e(t, "Tempo & Sync", "decks.temporange", "Tempo-Bereich (Standard)", kw: "pitch range"),
            e(t, "Tempo & Sync", "decks.phaselock", "Phase laufend nachführen (Beat-Sync)"),
            e(t, "Tempo & Sync", "decks.syncmode", "Sync-Modus"),
            e(t, "Tempo & Sync", "decks.bend", "Pitch-Bend-Stärke", kw: "nudge"),
            e(t, "Tempo & Sync", "decks.wavegrab", "Wellenform greifen",
              hint: "maus in der wellenform ohne taste, nicht im edit-modus: vinyl = teller, die position folgt der hand (scratch); jog = läuft das deck, pitch-bend nach der geschwindigkeit der hand, steht es, suchen. aus = nur suchen.",
              kw: "scratch jog vinyl nudge"),
            e("LIVE & SYNC", "Takt & Link", "decks.linkoffset", "Link-Versatz (ms)", kw: "link latenz"),
            e(t, l, "decks.loopsize", "Loopgröße (Standard)"),
            e(t, l, "decks.jumpsize", "Beatjump-Größe (Standard)"),
            e("DECKS", "Loop-Snap", "decks.loopsnap.cues", "Loop-Snap auf Loop-Cues",
              hint: "nur mit snap. loop, loop in: ein loop-cue, der bis zum fenster vor der position beginnt oder gerade überspielt wird, wird übernommen; sonst beginnt der loop auf der nächsten 4-takt-grenze (ab grid-anker) innerhalb der toleranz; sonst normaler snap. kein sprung: die position läuft in den loop hinein oder ist schon drin."),
            e("DECKS", "Loop-Snap", "decks.loopsnap.window", "Fenster (Beats)", kw: "loop-snap"),
            e("DECKS", "Loop-Snap", "decks.loopsnap.phrase", "Loop-Snap auf 4-Bar-Raster"),
            e("DECKS", "Loop-Snap", "decks.loopsnap.tolerance", "Toleranz (Beats)", kw: "loop-snap"),
            e(t, l, "decks.activeloop", "Active Loop greift",
              hint: "rechtsklick auf einen loop-hotcue -> active loop (punkt auf der taste, gestrichelter rahmen in der wellenform). erreicht die position den loop-anfang, rastet der loop ein, die loop-taste verlässt ihn. gespeichert je track in den eigenen änderungen."),
            e(t, l, "decks.autoloop", "Auto-Loop beim Laden",
              hint: "nur wenn der track keinen loop hat (loop-hotcue, loop-memory-cue). beginnt am ersten phrasenanfang (phrasen-anker, sonst grid-anker) im schnitt, nicht aktiv, rahmen mit AUTO in der wellenform. reloop springt hinein, loop übernimmt ihn ohne sprung, wenn die position darin oder kurz davor liegt. nicht gespeichert."),
        ] + DeckRows.all.map { e(t, "Zeilen je Deck", "decks.rows", $0.1, kw: "zeilen rows") } + [
            e(t, "Zeilen je Deck", "decks.compact", "Kompakte Decks (ohne Pitch-Fader, Hotcues, Grid-Werkzeuge)",
              hint: "auch im menü decks -> zeilen / kompakte decks. ohne pitch-fader nimmt die wellenform die breite. wellenform und kopfzeile bleiben immer."),
            e(t, "Größen", "decks.coversize", "Cover-Breite (pt)", alt: "decks.overviewheight"),
            e(t, "Größen", "decks.overviewheight", "Übersicht Höhe (pt)",
              hint: "für alle decks, wächst mit dem zoom. cover bis 40 pt im kopf, darüber eigene spalte links über kopf und wellenform; rechts bleiben mindestens 360 pt für titel und anzeigen, sonst wird das cover schmaler. cover an/aus: ⌘, -> browser -> cover. beide werte gehören zum ansichts-profil.",
              kw: "overview"),
            e("LIVE & SYNC", "Takt & Link", "decks.metronome", "Metronom auf Kanalpaar",
              hint: "im extern-modus z. b. auf das paar vom kopfhörer-cue legen -> klick nur auf dem kopfhörer", kw: "click"),
            e("DECKS", "Phrasen-Anker", "decks.phraseanchor", "Grid-Anker auf Phrasen ausrichten",
              hint: "beim laden prüft minos, ob die strukturwechsel des tracks auf 8-takt-grenzen ab dem grid-anker liegen. vorschlagen -> roter phrase-knopf in der grid-zeile, automatisch -> anker wird um ganze beats verschoben. bpm und raster bleiben, gespeichert in den eigenen änderungen, nie in der collection."),
            e("DECKS", "EDIT-Modus & Tool-Loops", "decks.edit.snap", "Raster beim Markieren", kw: "edit"),
            e("DECKS", "EDIT-Modus & Tool-Loops", "decks.edit.cutload", "Schneiden: Ergebnis ins Deck laden", kw: "edit cut"),
            e("DECKS", "EDIT-Modus & Tool-Loops", "decks.edit.toolfolder", "Tool-Loops in Ordner …",
              hint: "edit-modus: ziehen markiert auf dem raster, klick setzt eine schnittmarke, die zeile bearbeitet die schnittliste, das deck spielt sie. render schreibt <name> [cut].m4a, tool 2 · 4 · 8 · 16 schreibt <name> [tool-loop n].m4a.",
              kw: "edit"),
            e("DECKS", "Vorbereiten", "decks.prep.clip", "Vorbereiten AMP: Clipping erlauben (über 0 dBFS, Spitzen hart begrenzt)", kw: "prepare"),
            e("DECKS", "Vorbereiten", "decks.prep.jointempo", "Vorbereiten JOIN: Tempo der zweiten angleichen (bis ±0,5 %)",
              hint: "vorbereiten (profil oder deck-zeile): amp hebt nur an (samples × faktor, kein limiter), ohne clipping höchstens bis 0 dbfs, norm = spitze −0.3 dbfs. join hängt die zweite datei am nächsten taktanfang an, split teilt am takt. alles als neue datei neben dem original.",
              kw: "prepare"),
            e("DECKS", "Ausgabe (Render)", "decks.export.format", "Ausgabe: Format", kw: "export format wav aiff aac lossless"),
            e("DECKS", "Ausgabe (Render)", "decks.export.bits", "Ausgabe: Bit", kw: "export bit depth float 16 24"),
            e("DECKS", "Ausgabe (Render)", "decks.export.rate", "Ausgabe: Abtastrate", kw: "export sample rate resample 44.1 48 96"),
            e("DECKS", "Ausgabe (Render)", "decks.export.aac", "Ausgabe: AAC-Bitrate", kw: "export aac bitrate kbps"),
            e("DECKS", "Ausgabe (Render)", "decks.export.dither", "Ausgabe: Dither (TPDF) beim Schritt auf 16 Bit", kw: "export dither tpdf"),
            e("DECKS", "Ausgabe (Render)", "decks.export.pattern", "Ausgabe: Dateiname (Muster {name} {tag}, leer = wie bisher)", kw: "export name pattern"),
            e("LIVE & SYNC", "Groove → MIDI", "decks.groove.name", "Name der MIDI-Quelle", kw: "groove midi"),
            e("LIVE & SYNC", "Groove → MIDI", "decks.groove.bass", "Kanal Bass", kw: "groove midi"),
            e("LIVE & SYNC", "Groove → MIDI", "decks.groove.drums", "Kanal Drums", kw: "groove midi"),
            e("LIVE & SYNC", "Groove → MIDI", "decks.groove.octave", "Oktave Bass", kw: "groove midi"),
            e("LIVE & SYNC", "Groove → MIDI", "decks.groove.bars", "Länge ohne Loop", kw: "groove midi"),
            e("LIVE & SYNC", "Groove → MIDI", "decks.groove.offset", "Versatz (ms)",
              hint: "deck-zeile groove: muster des tracks am grid lesen (aktiver loop, sonst ab der nächsten eins), hats / bass dazu erzeugen. ▶ midi = virtuelle midi-quelle im takt der clock, in der daw als midi-eingang wählen. bass = grundton aus dem key, kanal 10 = drums (42 / 46 hats). ziehen aus dem raster oder .mid = midi-datei.",
              kw: "groove midi"),
        ]
    }()

    private static let mixerFX: [SettingsEntry] = {
        let t = "MIXER & FX", fx = "FX-Units (Insert-Slots)"
        return [
            e(t, "Mixer", "mixer.show", "Internen Mixer anzeigen"),
            e(t, "Mixer", "mixer.autogain", "Auto-Gain (Lautheit aus der Collection)"),
            e(t, "Mixer", "mixer.headroom", "Headroom", kw: "db"),
            e(t, "Mixer-Optionen", "mixer.eqkill", "EQ-Kill (ganz links = aus)"),
            e(t, "Mixer-Optionen", "mixer.xfader", "Crossfader-Kurve"),
            e(t, "Mixer-Optionen", "mixer.filterres", "Kanalfilter-Resonanz", kw: "filter"),
            e(t, "Auto-Mix", "automix.length", "Übergang (Takte)", hint: "Länge des Übergangs: 8, 16 oder 32 Takte. Start an der Phrasengrenze, die vor dem Outro liegt.", kw: "automix auto mix übergang crossfade bars takte"),

            e(t, "Auto-Mix", "automix.bassswap", "Bass-Tausch in der Mitte", hint: "in der Mitte des Übergangs wechselt der Bass: eingehend an, ausgehend aus. aus: der Bass bleibt bis zum Ende beim alten Track.", kw: "automix bass eq kill"),

            e(t, "Auto-Mix", "automix.sweep", "Filter-Sweep", hint: "eingehend startet mit leichtem Hochpass, ausgehend wird zum Ende hin tiefpass gefiltert.", kw: "automix filter hochpass tiefpass"),

            e(t, "Auto-Mix", "automix.keyclash", "Tonart-Konflikt erlauben", hint: "aus: Tracks mit Tonart-Konflikt (nicht benachbart, nicht relativ) scheiden bei der Auswahl aus.", kw: "automix key clash harmonie"),

            e(t, "Auto-Mix", "automix.keysync", "Key Sync beim Übergang", hint: "den eingehenden Track beim Laden auf die Tonart des ausgehenden drehen (wie Key Sync am Deck).", kw: "automix key sync tonart"),

            e(t, "Externer Mixer", "mixer.ext.headroom", "Headroom", kw: "extern db"),
            e(t, "Externer Mixer", "mixer.ext.autogain", "Auto-Gain", kw: "extern"),
            e(t, "Externer Mixer", "mixer.ext.mainvol", "Main-Volume wirkt auch extern"),
            e(t, "Externer Mixer", "mixer.ext.eq", "EQ im externen Modus",
              hint: "Aus: das Pult macht den EQ. An: EQ vor jedem Kanalpaar in MINOS-741, Regler im Mixer und am Deck.",
              kw: "pult desk eq"),
            e(t, fx, "fx.show", "FX-Units anzeigen", kw: "effekte effects insert slots"),
            e(t, fx, "fx.count", "Anzahl FX-Units", kw: "effekte effects insert slots"),
            e(t, fx, "fx.delayfb", "Delay-Feedback", kw: "slot"),
            e(t, fx, "fx.filterres", "FX-Filter-Resonanz",
              hint: "delay-feedback und filter-resonanz gelten für slots ohne eigenen wert (vorlage gruppe, neue delays) und für die filter in delay und roll.",
              kw: "slot roll"),
            e(t, fx, "fx.reverbtype", "Reverb-Typ", kw: "hall"),
            e(t, fx, "fx.reverblevel", "Reverb-Pegel (dB)", kw: "hall"),
            e(t, fx, "fx.reverbbright", "Reverb-Helligkeit", kw: "hall"),
            e(t, fx, "fx.reverbpredelay", "Reverb-Vorverzögerung (ms)", kw: "hall predelay"),
            e(t, "FX-Belegung (D/W · Regler · Tasten)", "fx.mapping", "Parameter suchen",
              hint: "rechtsklick auf einen regler oder eine taste der fx-unit wählt den parameter direkt – jeder parameter jedes slots. gilt für die unit und wird je rack gemerkt (effekte in reihenfolge): hat eine unit dieselben slots wieder, ist die belegung wieder da. die sitzung behält die belegung jeder unit. tasten: schalter um, listen eine stufe weiter, stufenlose zwischen min und max. d/w der unit wirkt nur, solange ein bedienelement darauf liegt.",
              kw: "fx-belegung mapping slot"),
            e(t, "Gemerkte Belegungen", "fx.mappings", "Gemerkte Belegungen", kw: "mapping rack vergessen"),
            e(t, "Gemerkte Racks", "fx.racks", "Gemerkte Racks", kw: "rack kette chain plugin vergessen"),
        ]
    }()

    private static let plugins: [SettingsEntry] = [
        e("PLUGINS", "Laden", "plugins.inprocess", "Plugins im Prozess (riskant)", kw: "isoliert absturz crash"),
        e("PLUGINS", "Laden", "plugins.isolate", "Drittanbieter-Plugins isoliert laden", alt: "plugins.inprocess"),
        e("PLUGINS", "Ordner", "plugins.folders", "Plugin installieren …", kw: "ordner vst3 component audio unit neu einlesen"),
        e("PLUGINS", "Plugins", "plugins.list", "Alle prüfen", kw: "auval suchen plugins"),
    ]

    private static let browser: [SettingsEntry] = {
        let t = "BROWSER", m = "◆ PASST (Matching)", c = "Collection", a = "Analyse", v = "Browser-Vorschau"
        return [
            e("BROWSER", "Zeilen & Felder", "browser.rowpadding", "Luft um den Text",
              hint: "zeilenhöhe = schrift + luft (11 pt = bisher, 5 pt = eng). gilt für alle listen, auch mit vorschau.", kw: "zeilenhöhe"),
            e("BROWSER", "Zeilen & Felder", "browser.rowlines", "Trennlinie zwischen den Zeilen"),
            e("BROWSER", "Zeilen & Felder", "browser.snaprows", "Höhe rastet auf ganze Zeilen"),
            e(t, "Zeilen & Felder", "browser.rows", "Zeilen", hint: "gilt für bereiche ohne eigene wahl; je bereich umschaltbar mit ≡ / ☰ und ▭ im kopf. werte kürzen: version im titel als kürzel (OM, EXT, RMX …), titel und artist in der mitte gekürzt, bpm ganzzahlig, datum kurz. sortierung und suche nutzen die vollen werte.",
              kw: "zweizeilig einzeilig two rows lines sammelspalte track"),
            e(t, "Zeilen & Felder", "browser.detailbar", "Detailleiste unter der Liste", kw: "detail bar details info leiste ▭"),
            e(t, "Zeilen & Felder", "browser.shortvalues", "Werte kürzen", kw: "kürzen short values original mix om ext rmx bpm datum"),
            e(t, "Zeilen & Felder", "browser.trackparts", "SPALTE TRACK (ZWEIZEILIG)", kw: "reihenfolge teile order parts kommentar zuerst vorlage"),
            e("ALLGEMEIN", "LIVE", "browser.live.auto", "Lesbarkeit bei LIVE automatisch", kw: "live auto club strobe dj"),
            e("ALLGEMEIN", "LIVE", "general.live.vst3", "VST3 bei LIVE überbrücken", hint: "Bei LIVE rechnen VST3-Plugins nicht mehr (Slot trocken): Absturzschutz, Audio Units bleiben aktiv",
              kw: "live vst3 plugin absturz crash überbrücken bypass sicher safety"),
            e("LIVE & SYNC", "Live-Lesbarkeit", "browser.live.on", "Live-Lesbarkeit in der Liste", kw: "live club strobe lesbar readable font"),
            e("LIVE & SYNC", "Live-Lesbarkeit", "browser.live.size", "Schriftgröße der Liste", kw: "live font size schrift groß"),
            e("LIVE & SYNC", "Live-Lesbarkeit", "browser.live.weight", "Schnitt", kw: "live weight medium semibold regular fett"),
            e("LIVE & SYNC", "Live-Lesbarkeit", "browser.live.stripes", "Zeilen abwechselnd getönt", kw: "live stripes alternating zebra"),
            e(t, "Gespielte Tracks", "browser.dimplayed", "Gespielte Tracks dimmen", kw: "played"),
            e(t, "Gespielte Tracks", "browser.hideplayed", "Gespielte Tracks ausblenden", kw: "played ungespielt"),
            e("ALLGEMEIN", "Start", "browser.resetplayed", "Played-Status beim Start zurücksetzen",
              hint: "gespielt = in der history (ab der schwelle unter history & preparation), bis zum zurücksetzen. ausblenden (auch ◆ UNGESPIELT im kopf des bereichs, menü browser) gilt für collection, playlists, smartlists, ordner und suche; history, running tracks und preparation zeigen sie weiter. zurücksetzen jederzeit: rechtsklick auf track collection (alles), auf playlist, smartlist, ordner, music folder, preparation oder auf markierte tracks (nur diese) -> reset played state. im baum mehrere einträge mit ⌘ / ⇧ markieren",
              kw: "played"),
            e(t, "History & Preparation", "browser.historythreshold", "Als gespielt nach (s hörbar)"),
            e(t, "History & Preparation", "browser.historyexternal", "History zusätzlich in den History-Ordner der Collection schreiben",
              hint: "history und preparation werden als nml gespeichert (~/Library/Application Support/MINOS-741) -> direkt in die collection importierbar. preparation wird bei jedem start archiviert und geleert."),
            e(t, "Vorhören", "browser.previewstart", "Vorhören im Browser ab (Anteil)", kw: "preview"),
            e(t, "Harmonie zum Master", "browser.harmony", "Key-Spalte färben", kw: "tonart harmonie camelot"),
            e(t, m, "browser.match.adjacent", "±1 auf dem Rad (▲▼)", kw: "matching key"),
            e(t, m, "browser.match.relative", "Relativ Dur/Moll (◇)", kw: "matching key"),
            e(t, m, "browser.match.energy", "Energie-Wechsel ±2", kw: "matching key"),
            e(t, m, "browser.match.bpm", "BPM-Fenster", kw: "matching"),
            e(t, m, "browser.match.groove", "Tag-Gruppen (Kommentar 2)", kw: "matching tags gruppen kick bass hats rolle"),
            e(t, m, "browser.match.halfdouble", "Halbes / doppeltes Tempo mitzählen",
              hint: "gleicher key zählt immer. track ohne key passt nicht, master ohne key: nur das tempo. an/aus: chip ◆ PASST im kopf des bereichs, tastatur (⌘, → tastatur) oder browse-taste am controller",
              kw: "matching"),
            e(t, v, "browser.preview.mode", "Vorschau", kw: "preview overview"),
            e(t, v, "browser.preview.colors", "Vorschau-Farben", kw: "preview"),
            e(t, v, "browser.preview.fill", "Vorschauen im Hintergrund berechnen", kw: "preview"),
            e(t, v, "browser.preview.textsize", "Schrift über dem Band", kw: "preview", alt: "browser.preview.mode"),
            e(t, v, "browser.preview.bold", "Schrift halbfett", kw: "preview", alt: "browser.preview.mode"),
            e(t, v, "browser.preview.band", "Band", kw: "preview", alt: "browser.preview.mode"),
            e(t, v, "browser.preview.bandspan", "Band-Breite",
              hint: "sichtbare breite: das band liegt nur über dem teil der zeile, den der browser zeigt, und bleibt beim scrollen im bild. ganze zeile: über alle spalten, auch die ausgescrollten",
              kw: "preview band breite width", alt: "browser.preview.mode"),
            e(t, "Cover", "browser.cover.deck", "Cover im Deck anzeigen", kw: "artwork"),
            e(t, "Cover", "browser.cover.preview", "Cover-Vorschau im Browser",
              hint: "vorschau unter dem baum (gewählter track). spalte „Cover“ in der liste: rechtsklick auf die spaltenköpfe. bild aus der datei, sonst cover / folder / front.jpg im ordner, zwischengespeichert in ~/Library/Caches/MINOS-741/artwork.",
              kw: "artwork"),
            e(t, c, "browser.musicfolders", "Musik-Ordner (MUSIC FOLDERS)"),
            e(t, c, "browser.writecollection", "Änderungen in die Collection-Datei schreiben (Backup davor)",
              hint: "aus: änderungen (inline, ⌘E, hotcues, loops, grid) liegen nur in MINOS-741 (metadata.json, edits.json). an: gesammelt in die collection.nml, sicherung höchstens stündlich in „Backup MINOS-741“ neben der datei. nicht, solange die collection-software läuft. schnitt und active loops bleiben in MINOS-741.",
              kw: "nml"),
            e(t, c, "browser.writecuts", "Cuts und Tool-Loops als neue Einträge anlegen"),
            e(t, c, "browser.writeplaylists", "Preparation, History und eigene Playlists als Playlists (Ordner MINOS-741)"),
            e("ALLGEMEIN", "Start", "browser.checkonstart", "Beim Start prüfen"),
            e(t, "Collection prüfen", "browser.checkfolders", "Musik-Ordner nach Dateien ohne Collection-Eintrag durchsuchen",
              hint: "browser-menü -> collection prüfen … oder rechtsklick auf TRACK COLLECTION. nur lesen: dateien, audio-kopf, dauer, schreibweise, namen, doppelte, analyse, grid, playlist-einträge. abbrechen jederzeit."),
            e("CLOUD", "TIDAL", "browser.tidal.clientid", "Client-ID", hint: TidalSettingsSection.hint, kw: "tidal login anmelden developer app"),
            e("CLOUD", "TIDAL", "browser.tidal.pattern", "Playlist-Name",
              hint: "Muster der Playlist für MISSING: %Y Jahr, %y zwei Stellen, %m Monat, %d Tag. Standard missing-%y%m%d", kw: "tidal playlist missing"),
            e("CLOUD", "TIDAL", "browser.tidal.signin", "Anmelden", kw: "tidal login anmelden"),
            e("CLOUD", "TIDAL", "browser.tidal.signout", "Abmelden", kw: "tidal logout abmelden"),
            e(t, a, "browser.bpmlow", "BPM-Bereich ab", kw: "tempo analyse"),
            e(t, a, "browser.bpmhigh", "BPM-Bereich bis",
              hint: "genau eine oktave: das tempo wird in den bereich gefaltet (z. b. 100–200: 96 -> 192). gilt für analysieren / neu analysieren.",
              kw: "tempo analyse"),
            e(t, a, "browser.rip", "Rip-Prüfung bei der Analyse mit",
              hint: "prüft anfang und ende: stille, rest eines anderen tracks (tonart, tempo), grid. ergebnis: spalte rip, ◆ RIP, ZU BEARBEITEN. rechtsklick -> rip prüfen geht immer."),
            e(t, a, "browser.ripmark", "Rip-Befund beim Laden markieren",
              hint: "lädt ein deck einen track mit offenem befund, wird der vorgeschlagene teil als bereich markiert (RIP · …). geschnitten wird nichts: rechtsklick -> markierten bereich entfernen."),
            e(t, a, "browser.auditheadroom", "Audio-Edit: Lautheit vorschlagen ab Reserve",
              hint: "audio-edit (AUDIO-EDIT, ⌘, -> KEYBOARD): ab dieser reserve unter 0 dBFS schlägt er NORM / AMP vor.",
              kw: "norm amp spitze headroom peak"),
            e(t, a, "browser.auditsnap", "Audio-Edit: Raster beim Markieren",
              hint: "beim eintritt in AUDIO-EDIT rastet die auswahl auf beats des grids ein. RASTER in der werkzeugzeile schaltet um; ohne diese einstellung ist es aus, freies markieren bis auf das sample.",
              kw: "audio edit raster snap grid beat markieren"),
            e(t, a, "browser.auditreset", "Import-Lauf und erledigt zurücksetzen",
              hint: "der nächste import analysieren nimmt wieder alle tracks ohne analyse und alle seit dem letzten lauf importierten. erledigt-markierungen fallen weg.",
              kw: "audio edit import reset"),
            e(t, a, "browser.keyprofiles", "Key-Profile lernen",
              hint: "lernt aus bis zu 300 lokalen tracks mit tonart aus der collection (keine downloads), im hintergrund wie die analyse. treffer auf jedem 5. track gemessen, der nicht gelernt wird. datei: key-profiles.json im MINOS-741-ordner. gilt für die nächste analyse.",
              kw: "tonart profile verwerfen"),
            e("LIVE & SYNC", "DAW-Brücke", "browser.daw", "Warp-Marker und Position aus der DAW empfangen (Remote Script)",
              hint: "remote script aus extras/daw-bridge in den ordner „Remote Scripts“ der DAW kopieren und dort als control surface wählen. nur 127.0.0.1, port gleich in config.json des scripts.",
              kw: "daw bridge"),
            e("LIVE & SYNC", "DAW-Brücke", "browser.dawport", "UDP-Port", kw: "daw bridge"),
        ]
    }()

    private static let tags: [SettingsEntry] = [
        e("BROWSER", "Tags (Kommentar 2)", "tags.separator", "Trennzeichen", kw: "separator kommentar"),
        e("BROWSER", "Tags (Kommentar 2)", "tags.highlight", "Tags farbig markieren"),
        e("BROWSER", "Tags (Kommentar 2)", "tags.groups", "Gruppen (K / B / H …)", kw: "gruppe marker kick bass hats rolle"),
        e("BROWSER", "Tag-Farben", "tags.colors", "Tag-Farben", kw: "farbe filtern"),
    ]

    private static let cloud: [SettingsEntry] = {
        let t = "CLOUD", k = "Lokal halten, solange MINOS-741 läuft"
        return [
            e(t, "Cloud-Library", "cloud.state", "Stand",
              hint: "spalte ☁ im browser: ● lokal · ☁ nur online · ↓ lädt · ✕ fehlt. rechtsklick auf tracks oder eine liste -> bereitmachen. set-check im browser-kopf: preparation + liste lokal? geprüft per dateistatus, ohne etwas zu laden; neu bei änderungen im ordner und alle 10 min.",
              kw: "cloud online"),
            e(t, "Cloud-Library", "cloud.checked", "Geprüft", kw: "cloud jetzt prüfen"),
            e(t, k, "cloud.keep", "Lokal halten", kw: "cloud download"),
            e(t, k, "cloud.parallel", "Gleichzeitige Downloads", kw: "cloud"),
            e(t, k, "cloud.minfree", "Mindestens frei lassen", kw: "cloud speicher gb"),
            e(t, k, "cloud.handoff", "Beim Beenden offene Downloads an den Anbieter übergeben",
              hint: "ausgelagerte tracks (speicher optimieren) werden neu geholt. lokal halten lädt einzeln und zuletzt, bereitmachen geht vor, neue downloads warten, solange ein deck lädt. übergeben: der anbieter lädt nach dem beenden weiter, ohne MINOS-741.",
              kw: "cloud"),
            e("CLOUD", "Dauerhaft offline", "cloud.folder", "Library-Ordner", kw: "cloud finder"),
            e("CLOUD", "Dauerhaft offline", "cloud.offline", "Offline verfügbar", kw: "cloud finder"),
            e("ALLGEMEIN", "Absturzberichte", "cloud.crash.ask", "Nach Absturz fragen",
              hint: "Beim nächsten Start zeigt MINOS-741 den bereinigten Bericht (ohne Pfade, Nutzer, Rechner, Geräte). Gesendet wird nur, was du in dem Fenster auslöst.",
              kw: "absturz crash bericht report frage github issue"),
            e("ALLGEMEIN", "Absturzberichte", "cloud.crash.on", "Vollständige Berichte in Ordner ablegen",
              hint: "Mit Ordner und eingeschalteter Option wird jeder neue Absturzbericht zusätzlich vollständig dort abgelegt. Nichts wird ins Netz geschickt.",
              kw: "absturz crash bericht report drive ordner"),
            e("ALLGEMEIN", "Absturzberichte", "cloud.crash.folder", "Ordner", kw: "absturz crash bericht ordner folder"),
        ]
    }()

    private static let keys: [SettingsEntry] = [
        e("CONTROLLER & TASTEN", "TASTATUR", "keys.reset", "ALLE ZURÜCKSETZEN", kw: "kürzel shortcut tasten standard"),
    ]

    private static let controller: [SettingsEntry] = {
        let t = "CONTROLLER & TASTEN", d = "Controller (nativ, HID)", b = "Belegung", l = "LEDs"
        return [
            e(t, d, "controller.devices", "Seite", kw: "links rechts a c b d"),
            e(t, d, "controller.devices", "Links", kw: "decks"),
            e(t, d, "controller.devices", "Rechts", kw: "decks"),
            e(t, d, "controller.devices", "Browser", kw: "bereich pane"),
            e(t, d, "controller.devices", "FX", kw: "fx-unit"),
            e(t, d, "controller.devices", "Blinken", kw: "identify"),
            e(t, d, "controller.devices", "Startsequenz", kw: "licht show"),
            e(t, b, "controller.cue", "Cue-Taste"),
            e(t, b, "controller.flux", "Flux-Taste"),
            e(t, b, "controller.fluxtap", "Flux antippen schaltet Flux-Modus", alt: "controller.flux"),
            e(t, b, "controller.shiftflux", "Shift + Flux", kw: "tap"),
            e(t, b, "controller.fluxpads", "Flux halten + Pads"),
            e(t, b, "controller.fluxjump", "Beatjump-Größe (Flux + Pad 3/4)"),
            e(t, b, "controller.strip", "Touchstrip"),
            e(t, b, "controller.stripsens", "Touchstrip-Empfindlichkeit"),
            e(t, b, "controller.browsefast", "Browse mit Shift"),
            e(t, b, "controller.shiftload", "Shift + LOAD"),
            e(t, b, "controller.browsepush", "Browse drücken",
              hint: "shift + drücken = vorhören. matching: filter „passt zum master“ im browser-bereich des controllers"),
            e("CONTROLLER & TASTEN", "LED-Helligkeit", "controller.ledon", "Helligkeit an", kw: "led"),
            e("CONTROLLER & TASTEN", "LED-Helligkeit", "controller.ledoff", "Helligkeit aus",
              hint: "pad-farben: ⌘, -> CONTROLLER -> Cue-Farben (gleich wie auf dem bildschirm)", kw: "led"),
            e(t, l, "controller.startshow", "Startsequenz beim Verbinden",
              hint: "rot / weiß / lila, dann die decks der seite auf der 7-segment-anzeige, weißer blitz, bereit (3,4 s). eine eingabe bricht ab.",
              kw: "led licht show"),
            e(t, "Feste Belegung (Standard)", "controller.fixed", "Feste Belegung (Standard)", kw: "play sync hotcues loop encoder"),
        ]
    }()
}

// MARK: - Suche

/// Suche ohne Groß/Klein und Akzente, deutsch und englisch; mehrere Wörter = alle müssen passen.
/// Rang: Name vor Stichwort vor Abschnitt vor Hinweis, Feldanfang vor Wortanfang vor Teilwort
struct SettingsSearch {
    struct Hit: Equatable {
        let entry: SettingsEntry
        let score: Int
    }

    /// sparsam: Suchwort -> weitere Wörter, die als Treffer zählen
    static let synonyms: [String: [String]] = [
        "samplerate": ["rate", "sample rate"], "rate": ["samplerate"], "abtastrate": ["samplerate", "rate"],
        "latenz": ["puffer", "buffer"], "latency": ["puffer", "buffer"], "puffer": ["latenz"], "buffer": ["latenz"],
        "bpm": ["tempo"], "tempo": ["bpm"],
        "volume": ["lautstarke", "pegel"], "lautstarke": ["volume", "pegel"],
        "shortcut": ["kurzel", "taste"], "hotkey": ["kurzel", "taste"],
        "colour": ["color", "farbe"],
    ]

    private struct Doc {
        let name: [UInt8], keywords: [UInt8], place: [UInt8], hint: [UInt8]
    }

    let entries: [SettingsEntry]
    private let docs: [Doc]

    /// `english`: Strings-Tabelle en (Schlüssel deutsch -> englisch)
    init(entries: [SettingsEntry], english: [String: String]) {
        self.entries = entries
        func both(_ k: String) -> String { english[k].map { k + " " + $0 } ?? k }
        docs = entries.map { e in
            Doc(name: Self.bytes(both(e.label)),
                keywords: Self.bytes(e.keywords.map(both).joined(separator: " ")),
                place: Self.bytes(both(e.tab) + " " + both(e.section)),
                hint: Self.bytes(e.hint.map(both) ?? ""))
        }
    }

    /// klein, ohne Akzente, ß -> ss, alles außer Buchstaben und Ziffern -> Leerzeichen
    static func fold(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ß", with: "ss")
        return String(f.map { $0.isLetter || $0.isNumber ? $0 : " " })
    }

    private static func bytes(_ s: String) -> [UInt8] { [32] + Array(fold(s).utf8) }

    /// Suchwörter (gefaltet)
    static func tokens(_ query: String) -> [String] { fold(query).split(separator: " ").map(String.init) }

    func search(_ query: String, limit: Int = 80) -> [Hit] {
        let toks = Self.tokens(query)
        guard !toks.isEmpty else { return [] }
        let needles: [[(bytes: [UInt8], weight: Int)]] = toks.map { t in
            [(Array(t.utf8), 10)] + (Self.synonyms[t] ?? []).map { (Array($0.utf8), 8) }
        }
        var hits: [Hit] = []
        for (i, d) in docs.enumerated() {
            var total = 0
            for alts in needles {
                var best = 0
                for (n, w) in alts {
                    best = max(best, w * Self.score(d, n))
                }
                if best == 0 { total = 0; break }
                total += best
            }
            if total > 0 { hits.append(Hit(entry: entries[i], score: total)) }
        }
        // stabil: gleicher Rang in Index-Reihenfolge
        return Array(hits.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element).prefix(limit))
    }

    private static func score(_ d: Doc, _ n: [UInt8]) -> Int {
        let fields: [([UInt8], Int, Int)] = [(d.name, 100, 60), (d.keywords, 50, 30), (d.place, 25, 15), (d.hint, 12, 6)]
        var best = 0
        for (hay, word, part) in fields where word > best {
            switch find(hay, n) {
            case 3: best = max(best, word + 1)     // Anfang des Namens (vor Wortanfang in der Mitte)
            case 2: best = max(best, word)
            case 1: best = max(best, part)
            default: break
            }
        }
        return best
    }

    /// 0 = nicht enthalten, 1 = Teilwort, 2 = Wortanfang
    private static func find(_ hay: [UInt8], _ n: [UInt8]) -> Int {
        let m = n.count, h = hay.count
        guard m > 0, h >= m else { return 0 }
        var found = 0
        hay.withUnsafeBufferPointer { hp in
            n.withUnsafeBufferPointer { np in
                let first = np[0]
                var i = 0
                while i <= h - m {
                    if hp[i] == first {
                        var j = 1
                        while j < m, hp[i + j] == np[j] { j += 1 }
                        if j == m {
                            if i == 1, hp[0] == 32 { found = 3; return }   // erstes Wort des Feldes
                            if i > 0, hp[i - 1] == 32 { found = 2; return }
                            found = 1
                        }
                    }
                    i += 1
                }
            }
        }
        return found
    }
}

extension SettingsSearch {
    /// Index mit der englischen Tabelle des App-Bundles (im Debug-Build aus dem Quellbaum)
    @MainActor static let shared = SettingsSearch(entries: SettingsIndex.entries, english: englishStrings())

    static func englishStrings() -> [String: String] {
        let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Localization/en.lproj/Localizable.strings")
        return (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
    }
}
