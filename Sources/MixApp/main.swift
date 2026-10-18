import SwiftUI
import AppKit
import MixCore
import MixEngine

/// Anordnung der Browser-Bereiche.
enum BrowserLayout: String, CaseIterable, Identifiable, Codable {
    case single = "Einzeln", sideBySide = "Nebeneinander", stacked = "Übereinander"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .single: "▭"
        case .sideBySide: "◫"
        case .stacked: "⬒"
        }
    }
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(MixModel.self) private var mix
    private var layout: BrowserLayout { mix.prefs.ui.browserLayout }
    @Environment(BrowserState.self) private var browserState
    private var paneA: BrowserPaneModel { browserState.paneA }
    private var paneB: BrowserPaneModel { browserState.paneB }
    /// Höhe der Deck-Fläche vor dem Zuklappen – ohne Beobachtung, Messen löst kein neues Layout aus
    private final class Height { var value: CGFloat = 0 }
    @State private var deckAreaHeight = Height()
    /// Decks fest in ihrer Höhe: während des Ziehens, kurz nach dem Loslassen und beim Umschalten Browser groß/klein.
    /// Sonst baute jeder Schritt das Deck-Layout und die Wellenform (Gitter, Kacheln) neu
    @State private var freezeDeck = false
    /// Browser-Höhe beim Zugbeginn: der Inhalt des Browsers bleibt darin, solange gezogen wird (sonst Tabelle je Bild neu)
    @State private var browserFrozen: Double?
    @State private var deckGate = DeckGate()
    @State private var donate = false

    var body: some View {
        VStack(spacing: 0) {
            PhraseLine()   // Phrasen-Fortschritt direkt unter der Werkzeugleiste
            // Decks oben, Browser unten – Trenner verschiebbar. Browser groß: Decks nur zusammengeklappt,
            // nicht neu aufgebaut (sonst dauert das Umschalten mit 14k Zeilen spürbar). Zugeklappt behalten sie
            // ihre letzte Höhe: kein neues Deck-Layout, keine neuen Wellenform-Kacheln
            let big = browserState.maximized
            let fixed: CGFloat? = (big || freezeDeck) && deckAreaHeight.value > 0 ? deckAreaHeight.value : nil
            deckArea
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !big && !freezeDeck { deckAreaHeight.value = $0 } }
                .frame(height: fixed)
                .frame(maxHeight: big ? 0 : .infinity, alignment: .top)
                .opacity(big ? 0 : 1)
                .allowsHitTesting(!big)
                .clipped()
                .layoutPriority(big ? 0 : 1)
            SplitArea(frozen: browserFrozen, onBegin: beginSplitDrag, onEnd: endSplitDrag) {
                BrowserAreas(layout: layout, paneA: paneA, paneB: paneB).equatable()
            }
            if mix.prefs.ui.statusBar == .always { statusBar }
        }
        .animation(.easeOut(duration: 0.1), value: browserState.maximized)   // Browser groß/klein: kurz, nur die Höhen
        .onChange(of: browserState.maximized) { _, big in
            if big { deckGate.gen += 1; freezeDeck = true } else { settleDeck() }
        }
        .overlay(alignment: .bottom) { if mix.prefs.ui.statusBar == .auto { AutoStatusBar() } }
        .background(Theme.background)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
        .preferredColorScheme(.dark)
        .toolbar {
            // Marke + Profil links, Statuszeile in der Mitte, Schalter rechts (WindowBar.swift)
            ToolbarItem(placement: .navigation) { WindowBrand() }.flat()
            ToolbarItem(placement: .principal) { WindowStatus() }.flat()
            ToolbarItem(placement: .primaryAction) { WindowSwitches() }.flat()
        }
        .toolbar(removing: .title)   // Titel steht als ◆ MINOS-741 + Version in der Leiste (Fenstertitel bleibt)
        .toolbarBackground(Theme.void, for: .windowToolbar)
        .windowToolbarFullScreenVisibility(.onHover)
        .background(MainWindowHook())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { n in
            if (n.object as? NSWindow) === MainWindow.window { ZoomControl.fit(mix: mix) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { n in
            if (n.object as? NSWindow) === MainWindow.window { ZoomControl.fit(mix: mix) }   // gespeicherter Zoom zu groß für den Bildschirm
        }
        .background(RunningTracks())
        .background(DAWBridgeHook())   // DAW-Brücke: Empfänger nach Einstellung, Clip je Deck
        .background(OverviewHook())   // Browser-Vorschau: Deck-Tracks, Pause-Regel, Leerlauf
        .background(CloudHook())      // Cloud-Library: Prüfen, Lokal-halten, Pause beim Laden
        .onChange(of: mix.prefs.ui.musicFolders, initial: true) { _, f in store.folders.configured = f }
        .onAppear {
            // Collection-Datei: eigene Hotcues / Grid schreiben und beim Laden auf Konflikte prüfen
            store.edits = mix.edits
            store.uiPrefs = { [mix] in mix.prefs.ui }
            store.updateUIPrefs = { [mix] change in change(&mix.prefs.ui) }
            store.onRefreshed = { [mix] t in mix.collectionUpdated(t) }
            if store.tracks.isEmpty { store.load() }
            SetupFlow.shared.checkAtStart(mix: mix)
            // MIX741_LAYOUT=nomixer,1deck,2decks,nobrowser: Teile der Oberfläche für Layout-Messungen abschalten (nur Selbsttest)
            if Session.isSelfTest, let l = ProcessInfo.processInfo.environment["MIX741_LAYOUT"] {
                if l.contains("nomixer") { mix.prefs.ui.showMixer = false }
                if l.contains("2decks") { mix.prefs.ui.deckCount = 2 }
                if l.contains("1deck") { mix.prefs.ui.deckCount = 1 }
                if l.contains("nobrowser") { mix.prefs.ui.browserLayout = .single; mix.prefs.ui.browserHeight = 120 }
            }
            mix.library = store   // Schneiden trägt neue Dateien in CUTS ein
            AudioEditMode.shared.attach(mix: mix, browser: browserState)
            RipChecks.shared.mix = mix
            RipChecks.shared.library = store
            Analyses.shared.onAnalysed = { [weak mix, weak store] key in mix?.analysisUpdated(key, store: store) }
            SelfTest.run(store: store, mix: mix, browser: browserState)
            SignalTestRun.runIfRequested(mix: mix)
            if DonateHint.dueNow { DonateHint.lastShown = Date(); donate = true }
        }
        .sheet(isPresented: $donate) { DonateView(shown: $donate) }
        .onReceive(NotificationCenter.default.publisher(for: .showDonate)) { _ in donate = true }
        // Einrichtung: beim Start nur wenn nötig (SetupFlow.checkAtStart), Menü „Einrichtung …“ jederzeit
        .sheet(isPresented: Binding(get: { SetupFlow.shared.sheetShown }, set: { if !$0 { SetupFlow.shared.close() } })) {
            SetupFlowView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSetup)) { _ in SetupFlow.shared.open() }
        // Absturz: beim Start gefragt, wenn ein neuer Bericht da ist (CrashReports.scheduleScan); nichts wird gesendet
        .sheet(isPresented: Binding(get: { CrashPrompt.shared.sheetShown }, set: { if !$0 { CrashPrompt.shared.close() } })) {
            CrashPromptView()
        }
    }

    /// RUNNING TRACKS im Browser nachführen – eigene leere Ansicht: liest alle vier Decks, ohne dass
    /// ContentView bei jeder Deck-Änderung neu ausgewertet wird
    struct RunningTracks: View {
        @Environment(LibraryStore.self) private var store
        @Environment(MixModel.self) private var mix
        var body: some View {
            Color.clear
                .onChange(of: mix.decks.map(\.trackKey), initial: true) { _, keys in
                    store.running = keys.filter { !$0.isEmpty }.compactMap { store.track($0) }
                }
        }
    }

    /// Browser-Höhe (unskaliert) auf ganze Tabellenzeilen rasten: Rahmen = Bereich ohne Tabelle plus Spaltenkopf
    /// (⌘, -> BROWSER „Höhe rastet auf ganze Zeilen“; nicht bei Browsern übereinander, dort teilt der Split die Höhe)
    private func snapBrowserHeight(_ h: Double) -> Double {
        let ui = mix.prefs.ui, m = paneA
        guard ui.browserSnapRows, layout != .stacked, m.paneHeight > 0, m.tableHeight > 0 else { return h }
        let chrome = (m.paneHeight - m.tableHeight + (24.z).rounded()) / 1.z
        // Live-Liste: Zeilenhöhe ohne Zoom
        let row = ui.liveListOn(live: mix.live) ? LiveList.rowHeight(LiveList.clampSize(ui.liveListTextSize))
            : TableStyle.rowHeight(ui, twoText: m.twoText(ui)) / 1.z
        return BrowserSnap.height(h, chrome: chrome, row: row)
    }

    /// Beginn des Ziehens am Trenner: Decks fest in ihrer Höhe
    private func beginSplitDrag() {
        deckGate.gen += 1
        freezeDeck = true
        browserFrozen = mix.prefs.ui.browserHeight
    }

    /// Ende des Ziehens am Trenner: auf ganze Zeilen einrasten und speichern (einmal, nicht bei jeder Bewegung)
    private func endSplitDrag(_ h: Double) {
        mix.prefs.ui.browserHeight = snapBrowserHeight(h)
        settleDeck()
    }

    /// Übergang läuft (Einrasten, Browser groß/klein): Decks bleiben bis zum Ende in ihrer Höhe, dann Layout neu.
    /// Ein neuer Übergang oder Zug davor hebt das auf (Zähler)
    private func settleDeck() {
        freezeDeck = true
        deckGate.gen += 1
        let g = deckGate.gen, gate = deckGate
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if gate.gen == g, !browserState.maximized { freezeDeck = false; browserFrozen = nil }
        }
    }

    /// Zähler für `settleDeck` (Klasse: der Zustand bleibt über Ansichtsaktualisierungen erhalten)
    final class DeckGate { var gen = 0 }

    /// Trenner und Browser-Fläche. Die Ziehhöhe lebt hier, nicht in ContentView: ein Zugschritt wertet nur diese Fläche
    /// neu aus, nicht die ganze Oberfläche (Werkzeugleiste, Deckbereich). `frozen`: Browser-Höhe beim Zugbeginn, der
    /// Inhalt bleibt darin, solange gezogen wird; sichtbar ist nur der Rahmen bis zur Maus (sonst Tabelle je Bild neu)
    struct SplitArea<Browsers: View>: View {
        @Environment(MixModel.self) private var mix
        @Environment(BrowserState.self) private var browserState
        @State private var dragHeight: Double?
        var frozen: Double?
        var onBegin: () -> Void
        var onEnd: (Double) -> Void
        @ViewBuilder var browsers: Browsers

        var body: some View {
            let big = browserState.maximized
            VStack(spacing: 0) {
                if !big {
                    SplitHandle(height: Binding(get: { dragHeight ?? mix.prefs.ui.browserHeight }, set: { dragHeight = $0 }),
                                onBegin: onBegin, onEnd: commit)
                        .onDisappear { commit() }   // Browser groß mitten im Ziehen: Höhe trotzdem speichern
                }
                browsers
                    .frame(height: big ? nil : frozen?.z)
                    .frame(height: big ? nil : (dragHeight ?? mix.prefs.ui.browserHeight).z, alignment: .top)
                    .clipped()
                    .frame(maxHeight: big ? .infinity : nil)
                    .layoutPriority(big ? 1 : 0)
            }
            .frame(maxHeight: big ? .infinity : nil)
            .layoutPriority(big ? 1 : 0)
        }

        /// Loslassen: Höhe einrasten (kurz animiert), Browser-Rahmen springt auf die gespeicherte Höhe
        private func commit() {
            guard let h = dragHeight else { return }
            withAnimation(.easeOut(duration: 0.1)) {
                onEnd(h)
                dragHeight = nil
            }
        }
    }

    /// Ziehbarer Trenner zwischen Decks und Browser; `onBegin` beim ersten Zug, `onEnd` beim Loslassen.
    /// Sichtbar 3 pt (Linie + 1 pt Luft), greifbar 9 pt: die Griff-Fläche ragt nach oben in den Deck-Rand (unten gewinnt der Browser)
    struct SplitHandle: View {
        @Binding var height: Double
        var snap: (Double) -> Double = { $0 }
        var onBegin: () -> Void = {}
        var onEnd: () -> Void = {}
        @State private var start: Double?
        var body: some View {
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.vertical, 1.z)
                .overlay {
                    Color.clear.frame(height: 9.z)
                        .contentShape(Rectangle())
                        .background(UITestMark(name: "split handle"))
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        // Fensterkoordinaten: der Griff wandert mit der Höhe, lokal gemessen würde die Verschiebung gegen die
                        // Bewegung zurückgedreht (Zittern). Höhe = Starthöhe − Verschiebung seit dem Griff
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                if start == nil { onBegin() }
                                let s = start ?? height
                                start = s
                                height = BrowserDrag.height(start: s, translation: g.translation.height / 1.z, snap: snap)
                            }
                            .onEnded { _ in start = nil; onEnd() })
                }
        }
    }

    private var deckArea: some View {
        let gap = max(0, min(12, mix.prefs.ui.deckGap)).z
        return VStack(spacing: 2.z) {
            TopBarHost()
            // Decks mit fester Höhe: zwei flexible Decks übereinander ließen SwiftUI jede Zustandsänderung
            // ~200 ms lang Layout rechnen (kombinatorische Messungen verschachtelter Stacks); jedes Deck in eigener
            // Hosting-View (DeckHost), damit eine Deck-Änderung nicht das ganze Fenster neu misst
            // 1 Deck: nur A über die volle Breite, B–D spielen unsichtbar weiter
            GeometryReader { geo in
                // Plätze aus ⌘, -> DARSTELLUNG -> Layout; ausgeblendete Decks spielen unsichtbar weiter
                let cols = DeckLayout.columns(visible: mix.visibleDecks, slots: mix.prefs.ui.deckSlots, twoSideBySide: mix.prefs.ui.twoDecksSideBySide)
                let rows = CGFloat(max(1, cols.left.count, cols.right.count))
                let deckH = max(120.z, (geo.size.height - (rows - 1) * gap) / rows)
                HStack(alignment: .top, spacing: gap) {
                    VStack(spacing: gap) {
                        ForEach(cols.left, id: \.self) { DeckHost(d: $0).frame(height: deckH, alignment: .top).clipped() }   // zu hoher Inhalt wird abgeschnitten, nie über die Leiste
                    }
                    if mix.prefs.ui.showMixer { MixerView().fixedSize(horizontal: true, vertical: false) }
                    if !cols.right.isEmpty {
                        VStack(spacing: gap) {
                            ForEach(cols.right, id: \.self) { DeckHost(d: $0).frame(height: deckH, alignment: .top).clipped() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // oben links verankert: GeometryReader zentriert sonst zu hohen Inhalt
            }
            .clipped()
        }
        .padding(.horizontal, gap)
        .padding(.top, max(gap, 2.z))
        .padding(.bottom, gap)
    }

    /// Browser-Bereiche (Equatable: ein Zugschritt baut sie nicht neu, solange Anordnung und Modelle gleich bleiben)
    struct BrowserAreas: View, Equatable {
        let layout: BrowserLayout
        let paneA: BrowserPaneModel
        let paneB: BrowserPaneModel
        static func == (a: BrowserAreas, b: BrowserAreas) -> Bool {
            a.layout == b.layout && a.paneA === b.paneA && a.paneB === b.paneB
        }

        /// Audio-Edit: Arbeitsliste und Vorschläge statt der Browser-Bereiche
        @ViewBuilder var body: some View {
            if AudioEditMode.shared.active {
                AudioEditArea()
            } else {
                switch layout {
                case .single:
                    BrowserPane(model: paneA)
                case .sideBySide:
                    HSplitView {
                        BrowserPane(model: paneA)
                        BrowserPane(model: paneB)
                    }
                case .stacked:
                    VSplitView {
                        BrowserPane(model: paneA)
                        BrowserPane(model: paneB)
                    }
                }
            }
        }
    }

    /// Statusleiste: Meldungen, Audio-Status, Last-Anzeigen (StatusBar.swift)
    private var statusBar: some View { StatusBar() }
}

/// Beenden nur nach Rückfrage (Sicherheit im Set); davor Sitzung und History schreiben
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (@MainActor () -> Void)?
    /// Dock-Menü: LIVE, Decks stoppen, Einstellungen, Einrichtung (Modell gesetzt in startControllers)
    let dockMenu = MainActor.assumeIsolated { DockMenu() }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { MainActor.assumeIsolated { dockMenu.menu() } }

    /// Fenster weg (auf welchem Weg auch immer) -> Beenden mit Rückfrage statt App ohne Fenster
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Session.isSelfTest else { return .terminateNow }
        // Ende-zu-Ende und Neustart nach Update: ohne Rückfrage, aber mit dem vollen Beenden (Sitzung, Einstellungen)
        if E2E.isActive || MainActor.assumeIsolated({ Updater.shared.relaunching }) {
            MainActor.assumeIsolated { onQuit?() }
            return .terminateNow
        }
        let a = NSAlert()
        a.messageText = String(localized: "MINOS-741 beenden?")
        a.informativeText = String(localized: "Sitzung und History werden gespeichert.")
        let pending = MainActor.assumeIsolated { CloudLibrary.shared.pendingCount }
        if pending > 0 {
            let handOff = MainActor.assumeIsolated { CloudLibrary.shared.handOffOnQuit }
            a.informativeText += "\n" + (handOff
                ? String(localized: "\(pending) Cloud-Downloads offen: der Anbieter lädt sie nach dem Beenden weiter.")
                : String(localized: "\(pending) Cloud-Downloads offen: sie werden abgebrochen."))
        }
        a.addButton(withTitle: String(localized: "Beenden"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        MainActor.assumeIsolated { onQuit?() }
        return .terminateNow
    }
}

struct MixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LibraryStore()
    @State private var mix = MixModel()
    @State private var browser = BrowserState()
    @State private var controllerStatus = ControllerStatus()
    @State private var waveforms = WaveformCache()
    @State private var history = HistoryStore()
    @State private var controller: ControllerManager?
    @State private var sessionTimer: Timer?


    /// Version, Codename und Build für die Marke in der Leiste („0.8.2 · LIMBUS · db052b1“), gleiche Quelle wie der Fenstertitel
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "dev" }
        let b = info?["CFBundleVersion"] as? String ?? ""
        let c = codename(info, version: v)
        return [v, c, b == v ? "" : b].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static var appTitle: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "MINOS-741 dev" }
        let b = info?["CFBundleVersion"] as? String ?? ""
        let c = codename(info, version: v)
        return "MINOS-741 " + [v, c].filter { !$0.isEmpty }.joined(separator: " · ") + (b.isEmpty || b == v ? "" : " (\(b))")
    }

    /// Codename aus dem Bundle (make-app.sh); ohne Schlüssel (swift run) aus der Version berechnet
    private static func codename(_ info: [String: Any]?, version: String) -> String {
        (info?["MINOSCodename"] as? String) ?? Codename.forVersion(version) ?? ""
    }

    var body: some Scene {
        WindowGroup(Self.appTitle) {
            MinSize(width: ZoomControl.minContent.width.z, height: ZoomControl.minContent.height.z) {
                ContentView()
                    .environment(store)
                    .environment(mix)
                    .environment(browser)
                    .environment(controllerStatus)
                    .environment(waveforms)
                    .environment(history)
            }
                .onAppear { startControllers() }
                .onChange(of: mix.prefs.controller) { controller?.prefs = mix.prefs.controller }
                .onChange(of: mix.prefs.ui.fxUnitCount) { controller?.fxUnits = mix.prefs.ui.fxUnitCount }
                .onChange(of: mix.prefs.ui.zoom) { ZoomControl.apply(mix.prefs.ui.zoom) }
                .onChange(of: mix.prefs.ui.pair) { PairLink.shared.configure(mix.prefs.ui.pair, history: history, mix: mix) }
        }
        Settings {
            SettingsView()
                .zoomExempt()
                .environment(mix)
                .environment(browser)
                .environment(store)
                .environment(controllerStatus)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // alle Kürzel aus den Einstellungen (⌘, -> Tastatur); ausgelöst werden sie vom KeyMonitor
            let keys = mix.prefs.keys
            let run = actions
            let model = mix, library = store   // für Fenster, die die Werte später selbst lesen
            CommandGroup(after: .newItem) {
                Button(ShortcutID.openCollection.title) { run(.openCollection) }
                    .shortcut(keys.combo(.openCollection))
            }
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(ShortcutID.settings.title) }
                    .shortcut(keys.combo(.settings))
            }
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "Über MINOS-741")) { AboutWindow.show() }
                Button(String(localized: "Nach Updates suchen …")) { Updater.shared.check(manual: true) }
            }
            CommandGroup(after: .appInfo) {
                let up = Updater.shared
                if let c = up.candidate, !up.installing {
                    Button(String(format: String(localized: "Update verfügbar: %@ (%@) – installieren …"),
                                  c.manifest.version, c.manifest.build)) { up.install() }
                }
                if up.hasPrevious {
                    Button(String(localized: "Vorherige Version wiederherstellen …")) { up.rollback() }
                }
            }
            CommandGroup(replacing: .help) {
                Button(String(localized: "MINOS-741 Handbuch")) { ManualWindow.show() }
                Button(String(localized: "Tastenkürzel")) { ShortcutWindow.show(keys: { model.prefs.keys }) }
                Divider()
                Button(String(localized: "Fehler melden …")) { CrashLinks.open(BugReport.url(BugReport.current())) }
                Button(String(localized: "Protokoll anzeigen")) { StatusLogWindow.show() }
                Divider()
                Button(String(localized: "Einrichtung …")) { NotificationCenter.default.post(name: .showSetup, object: nil) }
                Button(String(localized: "Kauf mir einen Kaffee …")) { NotificationCenter.default.post(name: .showDonate, object: nil) }
            }
            CommandGroup(replacing: .importExport) {
                Button(String(localized: "Einstellungen exportieren …")) { SettingsTransfer.exportAsking() }
                Button(String(localized: "Einstellungen importieren …")) { SettingsTransfer.importAsking(mix: model) }
                Divider()
                Button(String(localized: "Collection-Backup wiederherstellen …")) { CollectionBackupWindow.show(store: library) }
            }
            CommandGroup(replacing: .saveItem) {
                Button(String(localized: "Fenster schließen")) { run(.closeWindow) }
                    .shortcut(keys.combo(.closeWindow))
            }
            // Rückgängig der App (Deck, Browser); in Textfeldern bleibt die Taste das Text-Undo (KeyMonitor)
            CommandGroup(replacing: .undoRedo) {
                let u = UndoStack.shared
                Button(u.undoLabel.map { String(localized: "Rückgängig: \($0)") } ?? ShortcutID.undo.title) { run(.undo) }
                    .shortcut(keys.combo(.undo)).disabled(u.undoLabel == nil)
                Button(u.redoLabel.map { String(localized: "Wiederherstellen: \($0)") } ?? ShortcutID.redo.title) { run(.redo) }
                    .shortcut(keys.combo(.redo)).disabled(u.redoLabel == nil)
            }
            CommandGroup(before: .toolbar) {
                Toggle(String(localized: "Hilfe-Modus"), isOn: Binding(get: { HelpMode.shared.enabled }, set: { HelpMode.shared.enabled = $0 }))
                Divider()
                Toggle("Mixer", isOn: Binding(get: { mix.prefs.ui.showMixer }, set: { mix.prefs.ui.showMixer = $0 }))
                    .shortcut(keys.combo(.toggleMixer))
                Toggle("AUTO-MIX", isOn: Binding(get: { mix.autoMix.isOn }, set: { on in
                    if on { mix.autoMix.startFromPanes() } else { mix.autoMix.stop(String(localized: "Auto-Mix aus")) }
                }))
                .disabled(mix.mixerMode != .internalMixer)
                Picker("Decks", selection: Binding(get: { mix.prefs.ui.deckCount }, set: { mix.prefs.ui.deckCount = $0 })) {
                    Text("1 Deck").tag(1)
                    Text("2 Decks").tag(2)
                    Text("4 Decks").tag(4)
                }
                Button(ShortcutID.toggleFourDecks.title) { run(.toggleFourDecks) }
                    .shortcut(keys.combo(.toggleFourDecks))
                Toggle("Browser groß", isOn: Binding(get: { browser.maximized }, set: { browser.maximized = $0 }))
                    .shortcut(keys.combo(.bigBrowser))
                Picker("Browser-Anordnung", selection: Binding(get: { mix.prefs.ui.browserLayout }, set: { mix.prefs.ui.browserLayout = $0 })) {
                    ForEach(BrowserLayout.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Picker("Statusleiste", selection: Binding(get: { mix.prefs.ui.statusBar }, set: { mix.prefs.ui.statusBar = $0 })) {
                    ForEach(StatusBarMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Divider()
                Menu("Profil") {
                    let ui = mix.prefs.ui
                    ForEach(Array(ui.layoutProfiles.enumerated()), id: \.element.id) { i, p in
                        Toggle(isOn: Binding(get: { p.id.uuidString == ui.activeLayoutProfile },
                                             set: { _ in LayoutProfiles.apply(at: i, mix: mix, browser: browser, announce: false) })) {
                            Text(verbatim: p.name)
                        }
                        .shortcut(i < ShortcutID.profiles.count ? keys.combo(ShortcutID.profiles[i]) : nil)
                    }
                    Button(ShortcutID.profileNext.title) { run(.profileNext) }
                        .shortcut(keys.combo(.profileNext))
                        .disabled(ui.layoutProfiles.isEmpty)
                    Divider()
                    Button("Aktuelle Ansicht als Profil speichern …") { LayoutProfiles.saveAsking(mix: mix, browser: browser) }
                    Button("Profil aktualisieren") { LayoutProfiles.update(mix: mix, browser: browser) }
                        .disabled(ui.activeProfile == nil)
                    Button("Profil löschen …") { LayoutProfiles.deleteAsking(mix: mix) }
                        .disabled(ui.activeProfile == nil)
                }
                Button(ShortcutID.audioEdit.title) { run(.audioEdit) }
                    .shortcut(keys.combo(.audioEdit))
                Divider()
                ForEach([ShortcutID.zoomIn, .zoomOut, .zoomReset]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
            }
            CommandMenu("Decks") {
                ForEach([ShortcutID.focusDeckA, .focusDeckB, .focusDeckC, .focusDeckD]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                ForEach([ShortcutID.play, .cue, .cup, .sync, .master, .keylock, .keySync, .instantDouble, .loop, .reloop, .beatjumpBack, .beatjumpForward]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Button(ShortcutID.masterFX.title) { run(.masterFX) }.shortcut(keys.combo(.masterFX))
                Button(ShortcutID.record.title) { run(.record) }.shortcut(keys.combo(.record))
                Divider()
                ForEach([ShortcutID.hotcue1, .hotcue2, .hotcue3, .hotcue4, .hotcue5, .hotcue6, .hotcue7, .hotcue8]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                ForEach([ShortcutID.editMode, .cutIn, .cutOut, .gridSet]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                ForEach([ShortcutID.rangeRemove, .rangeKeep, .rangeTrim, .rangeLoop, .rangeClear]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Toggle("Schneiden: Ergebnis ins Deck laden", isOn: Binding(get: { mix.prefs.ui.cutLoadsResult },
                                                                            set: { mix.prefs.ui.cutLoadsResult = $0 }))
                Divider()
                ForEach([ShortcutID.editRemove, .editKeep, .editDuplicate, .editMute, .editLeft, .editRight, .editMark, .editSnap,
                         .editRender, .toolLoop2, .toolLoop4, .toolLoop8, .toolLoop16]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Menu("Vorbereiten") {
                    ForEach([ShortcutID.prepBIn, .prepBOut, .prepABA, .prepAnalyse, .prepAmpUp, .prepNorm, .prepAmpReset, .prepJoin,
                             .prepSplit, .prepRender]) { a in
                        Button(a.title) { run(a) }.shortcut(keys.combo(a))
                    }
                }
                Divider()
                Menu("Zeilen") {
                    ForEach(Array(DeckRows.all.enumerated()), id: \.offset) { _, row in
                        Toggle(LocalizedStringKey(row.1), isOn: Binding(get: { mix.prefs.ui[keyPath: row.0] },
                                                                      set: { mix.prefs.ui[keyPath: row.0] = $0 }))
                    }
                    Divider()
                    Button("Alle Zeilen") { mix.prefs.ui.showAllDeckRows() }
                }
                Toggle("Kompakte Decks", isOn: Binding(get: { mix.prefs.ui.compactDecks }, set: { mix.prefs.ui.compactDecks = $0 }))
                    .shortcut(keys.combo(.compactDecks))
            }
            CommandMenu("Browser") {
                ForEach([ShortcutID.resetPlayed, .loadSelected, .loadSelectedForce, .previewSelected, .reloadCollection, .matching]) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Toggle(String(localized: "Gespielte Tracks ausblenden"), isOn: Binding(get: { mix.prefs.ui.hidePlayedTracks }, set: { mix.prefs.ui.hidePlayedTracks = $0 }))
                    .shortcut(keys.combo(.hidePlayed))
                Button(String(localized: "Collection prüfen …")) { ConsistencyWindow.show(store: store) }
                Divider()
                ForEach(ShortcutID.favorites) { a in
                    Button(a.title) { run(a) }.shortcut(keys.combo(a))
                }
                Divider()
                Button(ShortcutID.reconnectAudio.title) { run(.reconnectAudio) }.shortcut(keys.combo(.reconnectAudio))
            }
        }
    }

    private var actions: AppActions { AppActions(mix: mix, browser: browser, store: store, history: history) }
}

extension MixApp {
    /// Controller auf der Steuer-Queue starten; Browser-Aktionen kommen auf dem Hauptthread zurück.
    @MainActor func startControllers() {
        MainStall.start()   // Lücken des Hauptthreads zählen (E2E: ui-stats)
        browser.store = store
        browser.history = history
        browser.separators = { [mix] in mix.prefs.ui.tagSeparators }
        history.start(store: store, mix: mix)
        E2EControl.start(mix: mix, store: store, browser: browser, history: history)   // nur mit MIX741_E2E_ROOT
        // Absturzberichte: Ordner nach der Einstellung; Suche 20 s nach dem Start (im Hintergrund), Frage nach Absturz
        CrashReports.configure(mix.prefs.ui)
        StatusLogFile.shared.beginRun(marker: CrashReports.runMarker(version: CrashReports.appVersion, build: CrashReports.buildNumber))
        CrashReports.scheduleScan(prefs: mix.prefs.ui, mix: mix)
        Updater.shared.start(mix: mix)   // Updates aus einem Ordner (ohne Ordner aus)
        PairLink.shared.configure(mix.prefs.ui.pair, history: history, mix: mix)
        store.history = history
        mix.autoMix.store = store
        mix.autoMix.history = history
        mix.autoMix.browser = browser
        appDelegate.dockMenu.mix = mix
        appDelegate.onQuit = { [mix, browser, history] in
            mix.recorder.stopNow()   // laufende Aufnahme sauber schließen (Tracklist dabei)
            Session.saveNow(mix: mix, browser: browser)
            mix.flushEdits()
            history.finish()
            SettingsFile.export(sync: true)
            CloudLibrary.shared.handOff()
        }
        let session = Session.load()
        session?.applyEngine(to: mix)
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [mix, browser] _ in
            MainActor.assumeIsolated { Session.saveIfChanged(mix: mix, browser: browser) }
        }
        // Preparation der letzten Session archivieren und leeren (einmal pro Start, nach dem Laden der Collection)
        store.onLoaded = { [store, history, browser] in
            guard !store.preparationArchived else { return }
            store.preparationArchived = true
            session?.applyBrowser(browser, store: store, history: history)
            if !store.preparation.isEmpty {
                history.archivePreparation(keys: store.preparation, date: store.preparationDate)
                store.preparation = []
            }
        }
        // Selbsttest: keine Controller anfassen (sonst steuert ein angeschlossener Controller die Test-Decks und umgekehrt)
        guard controller == nil, !Session.isSelfTest else { return }
        let m = ControllerManager(core: mix.core, status: controllerStatus)
        m.prefs = mix.prefs.controller
        m.fxUnits = mix.prefs.ui.fxUnitCount
        m.onBrowse = { [browser] pane, step in browser.moveSelection(by: step, pane: pane) }
        m.onLoad = { [browser, mix] pane, d, force in if let t = browser.selectedTrack(pane: pane) { mix.load(t, deck: d, force: force) } }
        m.onPreview = { [browser, mix] pane in if let t = browser.selectedTrack(pane: pane) { mix.togglePreview(t) } }
        m.onToggleBrowser = { [browser] in browser.maximized.toggle() }
        m.onMatching = { [browser] pane in browser.pane(pane).matching.toggle() }
        m.onSide = { [mix] key, side in mix.prefs.controller.sides[key] = side.rawValue }
        // alle Tastenkürzel (Belegung unter ⌘, -> Tastatur); Leertaste = Browser groß/klein, nicht beim Tippen in Suchfeldern
        KeyMonitor.install(actions)
        m.start()
        controller = m
    }
}

/// App-Icon: Lobster (Christians lobster2.png) – im Bundle als AppIcon.icns, beim Direktstart aus der Ressource
func setAppIcon() {
    if let url = AppResources.url("AppIcon", "png"),
       let img = NSImage(contentsOf: url) {
        NSApplication.shared.applicationIconImage = img
    }
}

// VST3-Selbsttest im eigenen Prozess (Einstellungen → PLUGINS → Prüfen): `<exe> --vst3-check <bundle> <klasse>`
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == PluginSelfCheck.argument {
    let info = PluginInfo.vst3(classID: CommandLine.arguments[3], name: URL(fileURLWithPath: CommandLine.arguments[2]).lastPathComponent,
                               vendor: "", version: "", path: CommandLine.arguments[2])
    let r = PluginSelfCheck.run(info)
    print(r.log)
    exit(r.passed ? 0 : 1)
}

SetupFlow.firstLaunch = E2E.defaults.data(forKey: AppPrefs.key) == nil   // vor der Übernahme alter Einstellungen (migrateDefaults)
AppResources.migrateDefaults()
SettingsFile.importIfChanged()   // Einstellungen aus dem Datenordner neben der Collection (anderer Mac, zurückgespielt)
SettingsFile.watch()
// Sprache aus den Einstellungen (vor dem ersten Fenster)
switch AppPrefs.load().ui.language {
case "de", "en": E2E.defaults.set([AppPrefs.load().ui.language], forKey: "AppleLanguages")
default: E2E.defaults.removeObject(forKey: "AppleLanguages")
}
Theme.registerFonts()
if !Session.isSelfTest { MainActor.assumeIsolated { ZoomControl.apply(AppPrefs.load().ui.zoom) } }   // Zoom vor dem ersten Layout, Selbsttest 100 %
MainActor.assumeIsolated { DeckShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=deck:…, kehrt dann nicht zurück
MainActor.assumeIsolated { GrooveShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=groove:…

// Selbsttest, nur Bild: MIX741_SHOT=wave:<png> | header:<png> rendert offscreen und beendet – kein Fenster
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("header:") {
    MainActor.assumeIsolated { HeaderShot.run(shot) }
}
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("wave:") {
    MainActor.assumeIsolated { WaveShot.run(path: String(shot.dropFirst(5))) }
}

// Selbsttest-Bild des Tastatur-Tabs: offscreen rendern und beenden (kein Fenster, keine Aktivierung, kein Audio)
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("keys:") {
    exit(MainActor.assumeIsolated { ShortcutShot.render(to: String(shot.dropFirst(5))) } ? 0 : 1)
}
// Selbsttest-Bild offscreen (kein Fenster, kein Audio): MIX741_SELFTEST=1 MIX741_SHOT=browser:<png>
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("browser:") {
    MainActor.assumeIsolated { BrowserShot.run(shot) }
}
// Browser-Vorschau offscreen: Bilder + Messung (MIX741_SELFTEST=1 MIX741_SHOT=preview:<ordner>)
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("preview:") {
    MainActor.assumeIsolated { PreviewShot.run(shot) }
}
MainActor.assumeIsolated { PreviewColorShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=previewcolors:<ordner>, kein Fenster
MainActor.assumeIsolated { CoverShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=cover:<ordner>, endet mit exit
MainActor.assumeIsolated { TagShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=tags:<ordner>, endet mit exit
MainActor.assumeIsolated { TableShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=table:<ordner>, endet mit exit
MainActor.assumeIsolated { SettingsShot.runPluginsIfRequested() }   // nur PLUGINS-Tab, ohne Audio: MIX741_SHOT=plugins:<ordner>
MainActor.assumeIsolated { SetupShot.runIfRequested() }
MainActor.assumeIsolated { CrashShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=crash:<png>, endet mit exit(0)   // nur Selbsttest mit MIX741_SHOT=setup:<png>, MIX741_SHOT_STEP=collection|music|audio|network|done
MainActor.assumeIsolated { BasicsShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=basics:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { SettingsShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=settings:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { StatusShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=status:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { CloudShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=cloud:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { ZoomShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=zoom:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { FXShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=fx:<ordner>, endet mit exit(0)
MainActor.assumeIsolated { WindowShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=window:<png>, endet mit exit
MainActor.assumeIsolated { PlaylistShot.runIfRequested() }   // nur Selbsttest mit MIX741_SHOT=playlists:<ordner>, endet mit exit
MainActor.assumeIsolated { UISelfTest.runIfRequested() }   // nur Selbsttest mit MIX741_UITEST=1, endet mit exit

if ToggleBench.requested { MainActor.assumeIsolated { ToggleBench.run() } }   // Messung offscreen, ohne Fenster
if ReloadBench.requested { MainActor.assumeIsolated { ReloadBench.run() } }   // Neu-Laden der Collection messen, offscreen
if ConsistencyCLI.requested { MainActor.assumeIsolated { ConsistencyCLI.run() } }   // Collection prüfen ohne Fenster, nur lesen
if Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("consistency:") {
    MainActor.assumeIsolated { ConsistencyShot.run(shot) }
}
// Als SwiftPM-Executable ohne Bundle: als normale App im Dock starten.
NSApplication.shared.setActivationPolicy(.regular)
if ProcessInfo.processInfo.environment["MIX741_SHOT"] == nil, !E2E.isActive { NSApplication.shared.activate(ignoringOtherApps: true) }
setAppIcon()
MixApp.main()

/// Browser-Höhe auf ganze Zeilen: `chrome` = alles außer den Zeilen (Kopf, Favoriten, Spaltenkopf), `row` = Zeilenhöhe
enum BrowserSnap {
    static func height(_ h: Double, chrome: Double, row: Double) -> Double {
        guard row > 0, h > chrome else { return h }
        let rows = max(1, ((h - chrome) / row).rounded())
        return chrome + rows * row
    }
}

/// Browser-Höhe beim Ziehen am Trenner: nur Starthöhe und Verschiebung seit dem Griff (unskaliert), nie die laufende Höhe.
/// Damit ist jede Verschiebung genau einer Höhe zugeordnet – das Einrasten wirkt nicht gegen die Bewegung
enum BrowserDrag {
    static func height(start: Double, translation: Double, snap: (Double) -> Double) -> Double {
        snap(max(120, min(900, start - translation)))
    }
}

extension Notification.Name {
    /// Spenden-Hinweis aus dem Hilfe-Menü öffnen
    static let showDonate = Notification.Name("minos741.showDonate")
    static let showSetup = Notification.Name("minos741.showSetup")
}
