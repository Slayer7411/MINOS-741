import SwiftUI
import AppKit
import MixCore
import MixEngine

/// LIVE & SYNC: Live-Lesbarkeit der Liste, Zwei Macs, Takt und Link, DAW-Brücke. ERWEITERT: Groove → MIDI
struct LiveSyncSettings: View {
    @Environment(MixModel.self) private var mix
    @Environment(\.settingsFilter) private var filter
    @Environment(\.settingsAdvancedPage) private var advancedPage

    var body: some View {
        @Bindable var mix = mix
        Form {
            if !advancedPage || filter != nil {
            Section("Live-Lesbarkeit") {
                Toggle("Live-Lesbarkeit in der Liste", isOn: $mix.prefs.ui.liveList)
                    .settingsAnchor("browser.live.on")
                sliderRow("Schriftgröße der Liste", $mix.prefs.ui.liveListTextSize, 11...18, step: 1, format: "%.0f", unit: "pt")
                    .settingsAnchor("browser.live.size")
                Picker("Schnitt", selection: $mix.prefs.ui.liveListWeight) {
                    ForEach(LiveListWeight.allCases) { Text($0.rawValue).tag($0) }
                }
                .settingsAnchor("browser.live.weight")
                Toggle("Zeilen abwechselnd getönt", isOn: $mix.prefs.ui.liveListStripes)
                    .settingsAnchor("browser.live.stripes")
                Text("live-liste: artist, title, bpm, key, time mit markerspalte vorn.")
                    .settingsHint()
                    .help("live-liste: spalten artist, title, bpm, key, time. vorn eine markerspalte: ✓ gespielt, ✕ datei fehlt, ☁ nur online, ✓ analysiert, rip-befund. alles knochenweiß, gespielte nicht gedimmt, ausgewählte zeile invertiert. schriftgröße unabhängig vom zoom, zeilenhöhe = schrift × 1,6. bei LIVE automatisch an, sonst von hand. die normale spaltenanordnung bleibt gespeichert, im live-modus wird nichts gespeichert.")
            }
            Section("Zwei Macs") {
                Toggle("Zwei-Mac-Modus", isOn: $mix.prefs.ui.pair.on)
                    .settingsAnchor("decks.pair")
                if mix.prefs.ui.pair.on {
                    Toggle("Dieser Mac schreibt (Collection, History)", isOn: $mix.prefs.ui.pair.writes)
                        .settingsAnchor("decks.pairwrites")
                    LabeledContent("Decks dieses Macs (höchstens 2)") {
                        HStack(spacing: 4) {
                            ForEach(0..<4, id: \.self) { d in
                                let on = mix.prefs.ui.pair.decks.contains(d)
                                Button { mix.prefs.ui.pair.decks = PairSetup.toggled(mix.prefs.ui.pair.decks, d) } label: {
                                    Text(verbatim: deckLetters[d])
                                        .font(Theme.label(12, .bold))
                                        .frame(width: 28, height: 22)
                                        .foregroundStyle(on ? Theme.void : Theme.muted)
                                        .background(on ? Theme.bone : Color.clear)
                                        .overlay(Rectangle().stroke(on ? Theme.bone : Theme.hairline, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .help(on ? "Deck \(deckLetters[d]) spielt auf diesem Mac" : "Deck \(deckLetters[d]) auf diesem Mac spielen")
                            }
                        }
                    }
                    .settingsAnchor("decks.pairdecks")
                    Toggle("Fernzugriff zum Analysieren erlauben", isOn: $mix.prefs.ui.pair.remoteDebug)
                        .settingsAnchor("decks.pairdebug")
                    PairingRows()
                }
                Text("zwei macs als eine session: jeder mac spielt seine decks, takt über link. genau ein mac schreibt in collection und history.")
                    .settingsHint()
                    .help("zwei macs als eine session: jeder spielt seine decks über sein eigenes interface ins pult (kanalpaare unter audio), takt über link (schaltet sich beim verbinden ein). genau ein mac schreibt in collection und history-ordner, der andere verbindet sich mit ihm. verbindung per ethernet, usb-c/thunderbolt-kabel oder gleiches netz, ohne einrichten. gespielt-markierungen gelten auf beiden. wirkt sofort; die anordnung der decks unter ANZEIGE -> Layout. bleibt auf diesem mac (nicht in settings.plist).")
            }
            Section("Takt & Link") {
                sliderRow("Link-Versatz (ms)", $mix.prefs.engine.linkOffsetMs, -50...50, step: 1, format: "%+.0f", unit: "ms")
                    .settingsAnchor("decks.linkoffset")
                Picker("Metronom auf Kanalpaar", selection: $mix.prefs.engine.metronomeChannel) {
                    ForEach(Array(stride(from: 0, to: max(2, mix.deviceChannels - 1), by: 2)), id: \.self) { c in
                        Text("\(c + 1)/\(c + 2)").tag(c)
                    }
                }
                .settingsAnchor("decks.metronome")
                Text("im extern-modus z. b. auf das paar vom kopfhörer-cue legen -> klick nur auf dem kopfhörer").settingsHint()
            }
            DAWBridgeSettings()
                if filter == nil { SettingsAdvancedLink(tab: "LIVE & SYNC") }
            }
            if advancedPage || filter != nil {
                SettingsAdvancedBack(tab: "LIVE & SYNC")
                GrooveSettingsSection()
            }
        }
    }
}
