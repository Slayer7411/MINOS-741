import SwiftUI
import MixCore
import MixEngine

// Werkzeugleiste des Fensters (CI-741): links Marke und Profil, Mitte Statuszeile, rechts Schalter.
// Darunter die Phrasenlinie. Jeder Wert ist eine eigene kleine Ansicht mit 10 Hz, der Balken selbst beobachtet nichts.

/// Schalter der Werkzeugleiste, Look wie DeckButton: 18 pt hoch, Radius 0, aktiv = gefüllt (rot = Zustand)
struct BarCell: View {
    let title: String
    var font: Font = Theme.label(10, .bold)
    var active = false
    var width: CGFloat = 18
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(font)
                .lineLimit(1)
                .foregroundStyle(active ? Theme.bone : Theme.bone.opacity(0.75))
                .frame(minWidth: width, minHeight: 18)
                .padding(.horizontal, 5)
                .background(Rectangle().fill(active ? Theme.state.opacity(0.85) : Theme.void))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Haarlinie zwischen den Gruppen der Werkzeugleiste
struct BarDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 18).padding(.horizontal, 6)
    }
}

/// Mehrere Schalter als eine Leiste mit einem gemeinsamen 1-px-Rahmen (1 / 2 / 4, Layout-Symbole)
struct BarSegments<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 0) { content }
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

extension ToolbarContent {
    /// macOS 26: keine Glas-Kapsel um die eigene Gruppe (Design: Radius 0, Haarlinien); älter: unverändert
    @ToolbarContentBuilder func flat() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

/// Links: ◆ MINOS-741 in Cinzel, Version und Build in Plex Mono, dann das Profil
struct WindowBrand: View {
    var body: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "◆ MINOS-741").font(Theme.label(12, .bold)).foregroundStyle(Theme.bone)
                Text(verbatim: MixApp.versionLine).font(Theme.mono(9)).foregroundStyle(Theme.muted)
            }
            .fixedSize()
            LayoutProfileMenu()
        }
    }
}

/// Mitte: Werte aus dem Mixer, Trenner ` · `. Passt die Leiste nicht, fallen die letzten Werte weg
struct WindowStatus: View {
    var body: some View {
        FirstFit {
            HStack(spacing: 0) {
                StatusClock(); StatusSep(); StatusBars(); StatusSep(); StatusLink(); StatusSep()
                StatusHID(); StatusSep(); StatusCPU(); StatusSep(); StatusTracks()
            }
            HStack(spacing: 0) {
                StatusClock(); StatusSep(); StatusBars(); StatusSep(); StatusLink(); StatusSep()
                StatusHID(); StatusSep(); StatusTracks()
            }
            HStack(spacing: 0) {
                StatusClock(); StatusSep(); StatusLink(); StatusSep(); StatusHID()
            }
        }
        .font(Theme.mono(10))
        .lineLimit(1)
    }
}

/// Name gedämpft, Wert knochenweiß; rot nur im Zustand
private struct StatusPair: View {
    let name: LocalizedStringKey
    let value: String
    var state = false
    var body: some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(Theme.muted)
            Text(verbatim: value).foregroundStyle(state ? Theme.state : Theme.bone)
        }
        .fixedSize()
    }
}

private struct StatusSep: View {
    var body: some View { Text(verbatim: " · ").foregroundStyle(Theme.muted) }
}

/// CLOCK: Tempo des Masters
private struct StatusClock: View {
    @Environment(MixModel.self) private var mix
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            StatusPair(name: "CLOCK", value: String(format: "%.2f", mix.clock.masterTempo))
        }
        .help("Tempo des Masters (Clock)")
    }
}

/// TAKT: Takt im Phrasen-Zyklus, wie der Takt-Zähler im Mixer
private struct StatusBars: View {
    @Environment(MixModel.self) private var mix
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let n = max(1, mix.prefs.ui.phraseBeats / 4)
            let bar = mix.core.sessionBeat.map { Int(max(0, $0) / 4) % n + 1 }
            StatusPair(name: "TAKT", value: bar.map { "\($0)/\(n)" } ?? "—/\(n)")
        }
        .help("Takt im Phrasen-Zyklus")
    }
}

/// LINK: Teilnehmer; rot, wenn Teilnehmer weg sind, während Link an ist
private struct StatusLink: View {
    @Environment(MixModel.self) private var mix
    @State private var lost = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let c = mix.clock
            StatusPair(name: "LINK", value: c.linkEnabled ? "● \(c.linkPeers)" : "○", state: lost)
        }
        .onChange(of: mix.clock.linkPeers) { old, new in
            if new > 0 { lost = false } else if old > 0 && mix.clock.linkEnabled { lost = true }
        }
        .onChange(of: mix.clock.linkEnabled) { _, on in if !on { lost = false } }
        .help("Link: ● Teilnehmer · rot = Teilnehmer weg")
    }
}

/// HID: angeschlossene Controller; rot, wenn weniger sind als vorher
private struct StatusHID: View {
    @Environment(ControllerStatus.self) private var ctl
    @State private var peak = 0
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let n = ctl.devices.count
            StatusPair(name: "HID", value: "×\(n)", state: n < peak)
        }
        .onChange(of: ctl.devices.count, initial: true) { _, n in peak = max(peak, n) }
        .help("Angeschlossene Controller · rot = einer fehlt")
    }
}

/// DSP: Anteil des Audio-Budgets je Block (wie die Lastanzeige); rot über 70 %
private struct StatusCPU: View {
    @Environment(MixModel.self) private var mix
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let s = MeterSampler.shared.sample
            StatusPair(name: "DSP", value: String(format: "%.0f %%", s.load.average * 100), state: s.load.average > 0.7)
        }
        .onAppear { MeterSampler.shared.attach(mix.engine) }
        .help("Audio-Last: Anteil der Zeit je Block · rot = über 70 %")
    }
}

/// TRACKS: Anzahl der Tracks in der Collection
private struct StatusTracks: View {
    @Environment(LibraryStore.self) private var store
    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: store.tracks.count.formatted()).foregroundStyle(Theme.bone)
            Text(verbatim: "TRACKS").foregroundStyle(Theme.muted)
        }
        .fixedSize()
    }
}

/// Rechts: MIXER | 1 2 4 | Layout-Symbole | DECKS | ↻ – Gruppen durch Haarlinien getrennt
struct WindowSwitches: View {
    @Environment(MixModel.self) private var mix
    @Environment(BrowserState.self) private var browser
    @Environment(LibraryStore.self) private var store
    /// Popover ★ (Favoriten der Einstellungen)
    @State private var favoritesOpen = false

    var body: some View {
        let ui = mix.prefs.ui
        let favorites = SettingsFavorites.resolved(ui.settingsFavorites, known: SettingsIndex.anchors)
        HStack(spacing: 0) {
            BarCell(title: "LIVE", active: mix.live, width: 30, help: "LIVE: kein Ruhezustand, kein Bildschirmschoner, Display bleibt an (gekoppelt: beide Macs)") {
                mix.setLive(!mix.live)
            }
            BarDivider()
            if !favorites.isEmpty {
                BarCell(title: "★", active: favoritesOpen, width: 22, help: "Favoriten: Einstellungen schnell ändern (ohne ⌘,)") {
                    favoritesOpen.toggle()
                }
                .popover(isPresented: $favoritesOpen, arrowEdge: .bottom) { FavoritesPopover(ids: favorites) }
                BarDivider()
            }
            if ui.pair.on {
                BarCell(title: "SCHREIBT", active: ui.pair.writes, width: 54, help: "Zwei Macs: dieser Mac schreibt in Collection und History; an = der andere gibt ab") {
                    mix.prefs.ui.pair.writes.toggle()
                }
                BarDivider()
                BarCell(title: "TAKT", active: mix.taktHere, width: 40, help: "Zwei Macs und B2B: an = dieser Mac übernimmt die Führung (Tempo und Takt für alle); aus = ein anderer führt, dieser folgt") {
                    PairLink.shared.claimTakt()
                }
                BarDivider()
                if PairLink.shared.info.count > 1 {
                    PairGroupStrip()
                    BarDivider()
                }
            }
            BarCell(title: "MIXER", active: ui.showMixer, help: "Internen Mixer ein-/ausblenden") {
                mix.prefs.ui.showMixer.toggle()
            }
            .background(UITestMark(name: "toolbar mixer"))
            BarDivider()
            BarSegments {
                ForEach([1, 2, 4], id: \.self) { n in
                    BarCell(title: "\(n)", font: Theme.mono(11), active: ui.deckCount == n, help: "Sichtbare Decks: 1 / 2 / 4") {
                        mix.prefs.ui.deckCount = n
                    }
                    .background(UITestMark(name: "toolbar decks \(n)"))
                }
            }
            BarDivider()
            BarSegments {
                ForEach(BrowserLayout.allCases) { c in
                    BarCell(title: c.icon, font: Theme.mono(12), active: ui.browserLayout == c, help: LocalizedStringKey(c.rawValue)) {
                        mix.prefs.ui.browserLayout = c
                    }
                }
            }
            BarDivider()
            BarCell(title: "AUDIO-EDIT", active: AudioEditMode.shared.active, help: "Audio-Edit: ein Deck, Arbeitsliste der Import-Analyse (⌘, → KEYBOARD)") {
                AudioEditMode.shared.toggle()
            }
            BarCell(title: "DECKS", active: !browser.maximized, help: "Decks ein-/ausblenden (Browser groß)") {
                browser.maximized.toggle()
            }
            BarDivider()
            BarCell(title: "↻", font: Theme.mono(13), help: "Collection neu laden") {
                store.load(store.sourceURL ?? LibraryStore.defaultNML)
            }
        }
    }
}

/// Phrasen-Fortschritt des Master-Decks: dünne Linie direkt unter der Werkzeugleiste, rot nur im letzten Takt vor dem
/// Phrasenwechsel. Ohne Master: einfache Haarlinie
struct PhraseLine: View {
    @Environment(MixModel.self) private var mix
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let len = Double(max(4, mix.prefs.ui.phraseBeats))
            let beat: Double? = mix.clockMaster || mix.effectiveMaster != nil ? mix.core.sessionBeat : nil
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.hairline))
                guard let beat else { return }
                let pos = max(0, beat).truncatingRemainder(dividingBy: len)
                let x = size.width * CGFloat(pos / len)
                let lastStart = size.width * CGFloat((len - 4) / len)
                ctx.fill(Path(CGRect(x: 0, y: 0, width: min(x, lastStart), height: size.height)), with: .color(Theme.muted))
                if x > lastStart {
                    ctx.fill(Path(CGRect(x: lastStart, y: 0, width: x - lastStart, height: size.height)), with: .color(Theme.state))
                }
            }
        }
        .frame(height: 2)
        .help("Phrase des Master-Decks · rot = letzter Takt vor dem Phrasenwechsel")
    }
}
