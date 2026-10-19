import SwiftUI
import MixCore

/// Rollen aus dem Mix-Steckbrief (Kommentar 2, „» BASIS“ usw.) als Schnellfilter.
enum RoleFilter: String, CaseIterable, Identifiable {
    case basis = "BASIS", synth = "SYNTH", drums = "DRUMS", voll = "VOLL", atmo = "ATMO"
    var id: String { rawValue }
}

/// Zustand eines Browser-Bereichs – jeder Bereich hat eigene Quelle, Suche, Sortierung, Auswahl, Tag-Filter.
@MainActor @Observable
final class BrowserPaneModel: Identifiable {
    /// Maße für das Einrasten der Browser-Höhe auf ganze Zeilen (ContentView.SplitHandle): Bereich, Tabelle (mit Kopf),
    /// Favoritenleiste – nur gelesen beim Ziehen, keine Beobachtung
    @ObservationIgnored var paneHeight: CGFloat = 0
    @ObservationIgnored var tableHeight: CGFloat = 0
    @ObservationIgnored var favoritesHeight: CGFloat = 0

    let id = UUID()
    var name: String
    var source: BrowserSource = .collection
    var search = ""
    var roles: Set<RoleFilter> = []
    /// gewählte Tags aus Kommentar 2 (alle müssen passen)
    var tags: Set<String> = []
    /// ausgeschlossene Tags (⌥-Klick): keiner darf vorkommen
    var excludedTags: Set<String> = []
    var sortOrder: [KeyPathComparator<Track>] = [KeyPathComparator(\Track.artist)]
    var selection: Set<Track.ID> = []
    var showTree = true
    /// MUSIC FOLDERS: Dateien aus allen Unterordnern zeigen
    var subfolders = false
    /// nur lokale Dateien (Cloud: ohne ☁ nur online / fehlend)
    var localOnly = false
    /// nur Tracks mit offenem Befund der Rip-Prüfung (◆ RIP)
    var ripOnly = false
    /// nur Tracks, die zum Master passen (Key-Stufen und BPM-Fenster aus ⌘, -> BROWSER)
    var matching = false
    /// Inline-Bearbeitung: Zelle (Track + Feld) und der Text im Feld
    var inline: InlineEdit?
    var inlineText = ""
    /// offenes Bearbeiten-Fenster (⌘E, Rechtsklick -> Bearbeiten …)
    var editSession: TrackEditSession?
    /// Favoritenleiste (6 Plätze, BrowserFavorites.swift)
    var favorites: [BrowserFavorite?] = BrowserFavorite.normalized(nil)
    /// Zeilen dieses Bereichs zweizeilig (nil = Einstellung ⌘, -> BROWSER), Symbol im Kopf
    var twoLine: Bool?
    /// Detailleiste dieses Bereichs (nil = Einstellung), Symbol im Kopf
    var detailBar: Bool?
    /// sichtbare Detailleiste (die Tabelle meldet ihr den Track direkt, ohne SwiftUI)
    @ObservationIgnored weak var detail: DetailBarView?
    @ObservationIgnored var onDetail: (() -> Void)?

    func twoText(_ ui: UIPrefs) -> Bool { twoLine ?? (ui.browserRows == .double) }
    func showsDetail(_ ui: UIPrefs) -> Bool {
        if let detailBar { return detailBar }
        switch ui.detailBar {
        case .auto: return twoText(ui)
        case .on: return true
        case .off: return false
        }
    }

    init(name: String, source: BrowserSource = .collection) {
        self.name = name
        self.source = source
    }

    /// Tags eines Tracks: Kommentar 2 an den eingestellten Trennzeichen zerlegt (einmal je Text, dann aus dem Speicher)
    static func tags(of t: Track, separators: String) -> [String] { tagIndex.entry(t.comment2, separators: separators).tags }
    static let tagIndex = TagIndex()

    @ObservationIgnored private var filterMemo = TagFilter()
    /// Tag-Filter aus `tags` + `excludedTags` (Vergleichsformen gemerkt)
    var tagFilter: TagFilter {
        let inc = tags, exc = excludedTags
        if filterMemo.include != inc || filterMemo.exclude != exc { filterMemo = TagFilter(include: inc, exclude: exc) }
        return filterMemo
    }

    /// Klick auf einen Tag: einschließen/lösen, ⌥ (`exclude`): ausschließen/lösen
    func toggleTag(_ tag: String, exclude: Bool) { setTagFilter(tagFilter.toggling(tag, exclude: exclude)) }
    func removeTag(_ tag: String) { setTagFilter(tagFilter.removing(tag)) }
    func clearTags() { tags = []; excludedTags = [] }
    private func setTagFilter(_ f: TagFilter) {
        if tags != f.include { tags = f.include }
        if excludedTags != f.exclude { excludedTags = f.exclude }
    }

    /// Tracks der Quelle vor Tag-Filter/Suche (für die Tag-Auswahl)
    func base(from store: LibraryStore, history: HistoryStore?) -> [Track] {
        if case let .prepArchive(s) = source { return (history?.prepKeys(s) ?? []).compactMap { store.byKey[$0] } }
        if case let .folder(p) = source { return store.folders.tracks(in: p, recursive: subfolders, library: store) }
        return store.tracks(for: source)
    }

    /// Bezug und Regel für Matching / Sortierung „Harmonie“ (gesetzt mit dem MixModel; in einer Ansicht gelesen,
    /// beobachtet sie so Key, Tempo und Regel – nur wenn der Bereich sie braucht)
    static var harmonySource: @MainActor () -> HarmonyInput = { HarmonyInput() }
    struct HarmonyInput: Hashable, Sendable {
        var ref: HarmonyRef?
        var rule = MatchRule()
        /// Gruppen des Bezugs-Tracks (nur mit `rule.groove`)
        var tags = TagProfile()
        /// weitere Bezugs-Decks: auch zu ihnen muss ein Track passen
        var extra: [HarmonyExtra] = []
    }
    struct HarmonyExtra: Hashable, Sendable {
        var ref: HarmonyRef
        var tags: TagProfile
    }

    var harmonySorted: Bool { sortOrder.contains { $0.keyPath == \Track.harmonySort } }

    /// Bezug nur, wenn Matching oder die Sortierung „Harmonie“ ihn braucht
    private func harmony() -> HarmonyInput? { matching || harmonySorted ? Self.harmonySource() : nil }

    @ObservationIgnored private var sortedKey: [AnyHashable] = []
    @ObservationIgnored private var sortedBase: [Track] = []
    @ObservationIgnored private var cacheKey: [AnyHashable] = []
    @ObservationIgnored private var cachedRows: [Track] = []
    /// Neuaufbau-Zähler: neu, wenn sich die Zeilen stark ändern (Quelle, Sortierung, Filter, Suche) – die Tabelle
    /// springt dann zur Auswahl bzw. nach oben, kleine Änderungen (neue Werte, ein paar Tracks) behalten die Position
    @ObservationIgnored private(set) var tableGeneration = 0
    /// Hintergrund-Liste fertig (beobachtet nur von der Anzahl im Kopf; die Tabelle bekommt sie über `onList`,
    /// ohne SwiftUI-Durchlauf)
    private(set) var listRevision = 0
    @ObservationIgnored var onList: (() -> Void)?
    /// laufende Hintergrund-Liste: Schlüssel + Nummer (ältere Ergebnisse verfallen)
    @ObservationIgnored private var jobKey: [AnyHashable] = []
    @ObservationIgnored private var jobSerial = 0

    /// zuletzt angezeigte Liste (Tabelle, Browse-Encoder) – nie neu sortiert
    var shown: [Track] { cachedRows }

    /// Zeilen, die „gespielte ausblenden“ zuletzt aus der Liste genommen hat (Anzahl im Kopf)
    @ObservationIgnored private(set) var hiddenCount = 0

    /// gespielte Tracks ausblenden (⌘, -> BROWSER, ◆ UNGESPIELT): nicht in History, RUNNING und Preparation (+ Archiv),
    /// dort stehen sie gerade deshalb bzw. sind vorgemerkt
    nonisolated static func hidesPlayed(in source: BrowserSource) -> Bool {
        switch source {
        case .historyLive, .history, .running, .preparation, .prepArchive: false
        default: true
        }
    }

    /// Schlüssel, die aus der Liste fallen (nil = keine)
    nonisolated static func hiddenKeys(source: BrowserSource, played: Set<String>, hidePlayed: Bool) -> Set<String>? {
        hidePlayed && !played.isEmpty && hidesPlayed(in: source) ? played : nil
    }

    private func excluded(_ history: HistoryStore?, _ hidePlayed: Bool) -> Set<String>? {
        Self.hiddenKeys(source: source, played: history?.played ?? [], hidePlayed: hidePlayed)
    }

    private func keys(_ store: LibraryStore, _ separators: String, _ h: HarmonyInput?, excl: Set<String>? = nil,
                      history: HistoryStore? = nil) -> (base: [AnyHashable], all: [AnyHashable]) {
        var base: [AnyHashable] = [source, "\(sortOrder)", store.revision, store.sourceRevision(source, subfolders: subfolders), subfolders]
        if harmonySorted, let h { base += [h.ref, h.rule.halfDouble] as [AnyHashable] }
        var all = base + [search, roles, tags, excludedTags, separators, localOnly, localOnly ? CloudLibrary.shared.revision : 0,
                          ripOnly, ripOnly ? RipChecks.shared.revision : 0,
                          excl != nil, excl != nil ? history?.playedRevision ?? 0 : 0] as [AnyHashable]
        if matching, let h { all += [h.ref, h.rule, h.tags, h.extra] as [AnyHashable] }
        return (base, all)
    }

    /// vorsortierte Liste der Collection (nicht für „Harmonie“: hängt am Bezug)
    private func presorted(_ store: LibraryStore) -> [Track]? { harmonySorted ? nil : store.presorted(source, order: sortOrder) }

    /// Gefilterte + sortierte Liste, sofort (Selbsttest, Messung). Die Quelle wird einmal sortiert (14k Tracks ≈ 80 ms,
    /// TrackSort) und bei Suche, Tags und Rollen nur noch gefiltert.
    func rows(from store: LibraryStore, history: HistoryStore?, separators: String, hidePlayed: Bool = false) -> [Track] {
        let h = harmony()
        let excl = excluded(history, hidePlayed)
        let (baseKey, key) = keys(store, separators, h, excl: excl, history: history)
        if baseKey != sortedKey {
            // nach dem Laden liegt die Liste meist schon sortiert vor (im Hintergrund, siehe LibraryStore.load)
            Self.dropLater(sortedBase)
            sortedBase = presorted(store) ?? TrackSort.sorted(base(from: store, history: history), using: sortOrder, rank: Self.rank(h))
            sortedKey = baseKey
        }
        if key == cacheKey { return cachedRows }
        let list = Self.filteredCounting(sortedBase, criteria(separators, h, excl), index: Self.tagIndex)
        apply(mainFilters(list.rows), key: key, hidden: list.hidden)
        return cachedRows
    }

    /// Liste für die Tabelle: Sortieren und Filtern im Hintergrund (Collection sortieren ~80 ms, Rollen filtern
    /// ~18 ms), bis dahin bleibt die angezeigte Liste stehen. Auch kleine Listen: die neue Liste kommt so in einem
    /// eigenen Durchlauf an, nicht zusammen mit Kopf, Baum und Favoriten (je Durchlauf < 1 Bild). Nur die erste sofort
    func list(from store: LibraryStore, history: HistoryStore?, separators: String, hidePlayed: Bool = false) -> [Track] {
        let h = harmony()
        let excl = excluded(history, hidePlayed)
        let (baseKey, key) = keys(store, separators, h, excl: excl, history: history)
        if key == cacheKey || key == jobKey { return cachedRows }
        if baseKey != sortedKey, let pre = presorted(store) {
            Self.dropLater(sortedBase)
            sortedBase = pre
            sortedKey = baseKey
        }
        if cacheKey.isEmpty { return rows(from: store, history: history, separators: separators, hidePlayed: hidePlayed) }
        let sorted = baseKey == sortedKey
        let base = sorted ? sortedBase : self.base(from: store, history: history)
        jobSerial += 1
        jobKey = key
        let serial = jobSerial
        let job = ListJob(base: base, order: sorted ? nil : sortOrder, criteria: criteria(separators, h, excl), rank: Self.rank(h))
        Task.detached(priority: .userInitiated) {
            let done = job.run()
            await MainActor.run { self.deliver(done, serial: serial, baseKey: baseKey, key: key) }
        }
        return cachedRows
    }

    /// neue Liste unterwegs (die Tabelle zeichnet für geänderte Tag-Markierungen erst mit ihr neu)
    var listPending: Bool { !jobKey.isEmpty }

    private func deliver(_ job: ListJob, serial: Int, baseKey: [AnyHashable], key: [AnyHashable]) {
        // verworfene Ergebnisse nicht hier freigeben
        defer { Self.dropLater(job.rows); if job.order != nil { Self.dropLater(job.base) } }
        guard serial == jobSerial else { return }
        jobKey = []
        guard key != cacheKey else { return }
        if job.order != nil {
            Self.dropLater(sortedBase)
            sortedBase = job.base
            sortedKey = baseKey
        }
        apply(mainFilters(job.rows), key: key, hidden: job.hidden)
    }

    @ObservationIgnored private var notifyPending = false

    /// neue Liste: Tabelle (`onList`) und Anzahl im Kopf (`listRevision`) danach, nie während einer Auswertung
    private func apply(_ rows: [Track], key: [AnyHashable], hidden: Int) {
        if !ListChange.isSmall(from: cachedRows, to: rows, limit: 64) { tableGeneration += 1 }
        Self.dropLater(cachedRows)
        cachedRows = rows
        cacheKey = key
        hiddenCount = hidden
        guard !notifyPending else { return }
        notifyPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notifyPending = false
                self.listRevision += 1
                self.onList?()
            }
        }
    }

    /// alte Listen nicht auf dem Hauptthread freigeben (6k Tracks: ~3 ms). Verzögert, damit die Tabelle ihre
    /// Kopie vorher losgelassen hat und die letzte Referenz im Hintergrund fällt
    nonisolated static func dropLater(_ old: [Track]) {
        guard old.count > 500 else { return }
        let box = ListJob(base: old, order: nil, criteria: Criteria(), rank: nil)
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1) { _ = box }
    }

    /// Bearbeiten-Fenster für die gewählten Tracks (Reihenfolge der Liste); ein Track -> PREV/NEXT durch die Liste
    func openEditor(_ ids: Set<Track.ID>, rows: [Track], store: LibraryStore) {
        let keys = rows.map(\.key)
        var sel = keys.filter { ids.contains($0) }
        if sel.isEmpty { sel = ids.sorted() }
        guard !sel.isEmpty, inline == nil else { return }
        editSession = TrackEditSession(selection: sel, list: keys, store: store)
    }

    /// Filter ohne Hauptthread-Zustand (Rollen, Tags, Suche, Matching); „nur lokal“ danach auf dem Hauptthread (`local`)
    struct Criteria: @unchecked Sendable {
        var roles: Set<RoleFilter> = []
        var tags = TagFilter()
        var words: [[UInt8]] = []
        var separators = ""
        var match: (ref: HarmonyRef, rule: MatchRule, tags: TagProfile, extra: [HarmonyExtra])?
        /// gespielte Tracks (Schlüssel), die nicht in der Liste stehen sollen
        var exclude: Set<String>?
        var isEmpty: Bool { roles.isEmpty && tags.isEmpty && words.isEmpty && match == nil && exclude == nil }
    }

    private func criteria(_ separators: String, _ h: HarmonyInput?, _ excl: Set<String>? = nil) -> Criteria {
        Criteria(roles: roles, tags: tagFilter, words: search.split(separator: " ").map { Track.fold(String($0)) }, separators: separators,
                 match: matching ? h.flatMap { h in h.ref.map { ($0, h.rule, h.tags, h.extra) } } : nil, exclude: excl)
    }

    /// Sortierwert „Harmonie“ (nur mit Bezug)
    nonisolated private static func rank(_ h: HarmonyInput?) -> (@Sendable (Track) -> Double)? {
        guard let h, let ref = h.ref else { return nil }
        let rule = h.rule
        return { rule.rank($0, ref) }
    }

    /// Sortieren (falls `order`) und Filtern im Hintergrund, eigener Tag-Index (der geteilte gehört dem Hauptthread)
    final class ListJob: @unchecked Sendable {
        private(set) var base: [Track]
        let order: [KeyPathComparator<Track>]?
        let criteria: Criteria
        let rank: (@Sendable (Track) -> Double)?
        private(set) var rows: [Track] = []
        private(set) var hidden = 0
        init(base: [Track], order: [KeyPathComparator<Track>]?, criteria: Criteria, rank: (@Sendable (Track) -> Double)?) {
            self.base = base
            self.order = order
            self.criteria = criteria
            self.rank = rank
        }
        func run() -> ListJob {
            if let order { base = TrackSort.sorted(base, using: order, rank: rank) }
            (rows, hidden) = BrowserPaneModel.filteredCounting(base, criteria, index: TagIndex())
            return self
        }
    }

    nonisolated static func filtered(_ base: [Track], _ c: Criteria, index: TagIndex) -> [Track] {
        filteredCounting(base, c, index: index).rows
    }

    /// gefiltert + Anzahl der ausgeblendeten gespielten Tracks (nach allen anderen Filtern)
    nonisolated static func filteredCounting(_ base: [Track], _ c: Criteria, index: TagIndex) -> (rows: [Track], hidden: Int) {
        var list = base
        if !c.roles.isEmpty {
            // `» BASIS` im Text oder `BASIS` als ganzer Tag
            let needles = c.roles.map { "» " + $0.rawValue }, keys = c.roles.map { Tags.key($0.rawValue) }
            list = list.filter { t in
                needles.contains { t.comment2.localizedCaseInsensitiveContains($0) }
                    || keys.contains(where: index.entry(t.comment2, separators: c.separators).keys.contains)
            }
        }
        if !c.tags.isEmpty {
            list = list.filter { c.tags.matches(keys: index.entry($0.comment2, separators: c.separators).keys) }
        }
        if !c.words.isEmpty { list = list.filter { $0.matches(words: c.words) } }
        if let m = c.match {
            // alle Bezüge: erstes Deck (oder AUTO) und die weiteren gewählten
            let refs = [HarmonyExtra(ref: m.ref, tags: m.tags)] + m.extra
            for r in refs { list = list.filter { m.rule.matches($0, r.ref) } }
            if m.rule.groove != .off {
                for r in refs where !r.tags.isEmpty {
                    list = list.filter { let e = index.entry($0.comment2, separators: c.separators); return m.rule.matchesTags(TagProfile(tags: e.tags, groups: e.groups), r.tags) }
                }
            }
        }
        guard let x = c.exclude else { return (list, 0) }
        let kept = list.filter { !x.contains($0.key) }
        return (kept, list.count - kept.count)
    }

    /// Filter mit Hauptthread-Zustand: nur lokal, nur offene Rip-Befunde
    private func mainFilters(_ list: [Track]) -> [Track] {
        var l = localOnly ? Self.local(list) : list
        if ripOnly { let open = RipChecks.shared.openKeys; l = l.filter { open.contains($0.key) } }
        return l
    }

    private static func local(_ list: [Track]) -> [Track] {
        let c = CloudLibrary.shared
        return list.filter { c.isLocal($0.path) }
    }
}

struct BrowserPane: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Environment(MixModel.self) private var decks
    @Bindable var model: BrowserPaneModel
    @Environment(BrowserState.self) private var browserState

    var body: some View {
        // Zeilen liest nur die Tabelle (TrackTable) und die Anzahl im Kopf: eine neue Liste aus dem Hintergrund wertet
        // nicht den ganzen Bereich neu aus (Favoriten, Baum, Kopf)
        // Baum bleibt im Split, ausgeblendet = Breite 0 (nur der 1-pt-Trenner bleibt): Entfernen/Einsetzen des
        // Split-Elements hängte jede Zeile aus dem Fenster aus und wieder ein (~850 ms beim Umschalten Browser groß ⇄ Decks)
        let tree = model.showTree && !(decks.prefs.ui.hideTreeWithDecks && !browserState.maximized)
        VStack(spacing: 0) {
        FavoritesBar(model: model, keys: decks.prefs.keys)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.favoritesHeight = $0 }
        HSplitView {
            SourceTree(selection: $model.source)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if tree && decks.prefs.ui.showCoverPreview { CoverPreview(model: model) }   // Cover des gewählten Tracks
                }
                .frame(minWidth: tree ? 170.z : 0, idealWidth: tree ? 210.z : 0, maxWidth: tree ? 320.z : 0)
            // Browser übereinander: Kopf als Spalte links neben der Liste, die Höhe gehört ganz den Zeilen
            let side = decks.prefs.ui.browserLayout == .stacked
            HStack(spacing: 0) {
                if side {
                    PaneHeader(model: model, side: true)
                        .background(UITestMark(name: "pane side \(model === browserState.paneA ? "A" : "B")"))
                }
                VStack(spacing: 0) {
                    if !side { PaneHeader(model: model) }
                    if model.source == .daw { DAWClipsPanel() }
                    if model.source.isHistory {
                        HistoryTable(entries: Self.historyEntries(model.source, history), model: model)
                    } else {
                        TrackTable(model: model)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.tableHeight = $0 }
                        if model.showsDetail(decks.prefs.ui) { DetailBar(model: model) }
                    }
                }
                .frame(minWidth: 380.z)
            }
        }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.paneHeight = $0 }
        .background {
            // ⌘E: Bearbeiten-Fenster für die Auswahl (nur der zuletzt benutzte Bereich reagiert)
            if browserState.activePane.id == model.id, !model.source.isHistory {
                Button("") { model.openEditor(model.selection, rows: model.shown, store: store) }
                    .keyboardShortcut("e", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .sheet(item: $model.editSession) { session in
            TrackEditPanel(session: session) { key in
                model.selection = [key]
                browserState.scrollRequest = (model.id, key)
            }
            .zoomExempt()   // Dialog bleibt bei 100 %
        }
        .onChange(of: decks.prefs.ui.writeCollection) { _, on in if on { store.scheduleWriteBack() } }
    }

    static func historyEntries(_ source: BrowserSource, _ history: HistoryStore) -> [HistoryEntry] {
        switch source {
        case .historyLive: history.live
        case let .history(s): history.entries(s)
        default: []
        }
    }
}

/// Anzahl der Zeilen im Kopf (eigene Ansicht: hängt an der Liste, der Kopf nicht)
struct RowCount: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Environment(MixModel.self) private var decks
    let model: BrowserPaneModel

    var body: some View {
        let _ = model.listRevision
        let n = model.source.isHistory ? BrowserPane.historyEntries(model.source, history).count
            : model.list(from: store, history: history, separators: decks.prefs.ui.tagSeparators, hidePlayed: decks.prefs.ui.hidePlayedTracks).count
        let hidden = model.source.isHistory || !decks.prefs.ui.hidePlayedTracks ? 0 : model.hiddenCount
        (hidden > 0 ? Text("\(n) · \(hidden) ausgeblendet") : Text(verbatim: "\(n)"))
            .font(Theme.mono(11.z)).foregroundStyle(Theme.muted).fixedSize()
    }
}

/// Kopf eines Bereichs: Quelle, Anzahl, Suche, Rollen, Tags, Lokal
struct PaneHeader: View {
    @Environment(MixModel.self) private var decks
    @Bindable var model: BrowserPaneModel
    /// Spalte links neben der Liste (Browser übereinander: die Höhe gehört den Zeilen) statt zwei Kopfzeilen
    var side = false
    @State private var showTags = false

    static let sideWidth: CGFloat = 176

    var body: some View {
        if side {
            // scrollt, wenn der Bereich niedriger ist als die Spalte (viele Filter, viele Tags)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6.z) {
                    titleRow
                    search.frame(maxWidth: .infinity)
                    if case .folder = model.source { subfolders }
                    Wrap(spacing: 4.z) { roles }
                    Wrap(spacing: 4.z) {
                        tagsButton
                        MatchChip(model: model)
                        UnplayedChip()
                        RipChip(model: model)
                        if CloudLibrary.shared.hasCloudTracks { cloud }
                    }
                    if !model.tagFilter.isEmpty {
                        Wrap(spacing: 3.z) {
                            DeckButton(title: "✕ TAGS") { model.clearTags() }.help("Tag-Filter löschen")
                            activeTags
                        }
                    }
                }
                .padding(6.z)
            }
            .frame(width: Self.sideWidth.z, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panelHeader)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
        } else {
            VStack(alignment: .leading, spacing: 4.z) {
                HStack(spacing: 8.z) {
                    titleRow
                    if case .folder = model.source { subfolders }
                    Spacer(minLength: 8.z)
                    search.frame(minWidth: 120.z, maxWidth: 220.z)
                }
                HStack(spacing: 4.z) {
                    roles
                    Text("│").foregroundStyle(Theme.hairline)
                    tagsButton
                    Text("│").foregroundStyle(Theme.hairline)
                    MatchChip(model: model)
                    UnplayedChip()
                    RipChip(model: model)
                    if CloudLibrary.shared.hasCloudTracks {
                        Text("│").foregroundStyle(Theme.hairline)
                        cloud
                    }
                    // aktiver Tag-Filter: eingeschlossene gefüllt, ausgeschlossene durchgestrichen – Klick löst den Tag
                    if !model.tagFilter.isEmpty {
                        if CloudLibrary.shared.hasCloudTracks { Text("│").foregroundStyle(Theme.hairline) }
                        DeckButton(title: "✕ TAGS") { model.clearTags() }
                            .help("Tag-Filter löschen")
                        ScrollView(.horizontal, showsIndicators: false) {
                            TagChips(tags: model.tags.sorted() + model.excludedTags.sorted(), ui: decks.prefs.ui,
                                     filter: model.tagFilter) { t, _ in model.removeTag(t) }
                                .font(Theme.mono(11.z))
                        }
                    }
                }
            }
            .padding(.horizontal, 8.z)
            .padding(.vertical, 3.z)
            .background(Theme.panelHeader)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8.z) {
            Button { model.showTree.toggle() } label: { Text("◧").font(Theme.mono(13.z)).foregroundStyle(Theme.bone) }
                .buttonStyle(.borderless)
                .help("Baum ein/aus")
            Text(model.source.title.uppercased()).font(Theme.label(13.z, .bold)).lineLimit(1)
            RowCount(model: model)
            if model.source == .missing { TidalMissingButton() }
            OwnSmartlistEditButton(model: model)
            if !model.source.isHistory { RowsButtons(model: model) }
        }
    }

    private var subfolders: some View {
        DeckButton(title: "UNTERORDNER", active: model.subfolders) { model.subfolders.toggle() }
            .help("Dateien aus allen Unterordnern zeigen")
    }

    private var search: some View {
        SearchField(model: model)
            .textFieldStyle(.plain)
            .font(Theme.mono(11.z))
            .padding(.horizontal, 6.z).padding(.vertical, 3.z)
            .background(Theme.void)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private var roles: some View {
        ForEach(RoleFilter.allCases) { r in
            DeckButton(title: r.rawValue, active: model.roles.contains(r)) {
                if model.roles.contains(r) { model.roles.remove(r) } else { model.roles.insert(r) }
            }
        }
    }

    private var tagsButton: some View {
        DeckButton(title: "TAGS ▾", active: showTags) { showTags.toggle() }.helpInfo("browser.tags")
            .popover(isPresented: $showTags, arrowEdge: .bottom) {
                TagPicker(model: model, separators: decks.prefs.ui.tagSeparators)
            }
    }

    @ViewBuilder private var cloud: some View {
        DeckButton(title: "● LOKAL", active: model.localOnly) { model.localOnly.toggle() }
            .help("Nur lokale Tracks (ohne ☁ nur online)")
        SetCheckButton(model: model)
    }

    /// aktiver Tag-Filter einzeln (Seitenspalte): eingeschlossene gefüllt, ausgeschlossene durchgestrichen, Klick löst den Tag
    private var activeTags: some View {
        ForEach(model.tags.sorted() + model.excludedTags.sorted(), id: \.self) { t in
            Button { model.removeTag(t) } label: { TagChip(tag: t, mark: model.tagFilter.mark(t), style: .of(t, decks.prefs.ui)) }
                .buttonStyle(.plain)
                .font(Theme.mono(11.z))
        }
    }
}

/// Symbole im Kopf: Zeilen ein-/zweizeilig, Detailleiste ein/aus (je Bereich, in der Sitzung gespeichert)
struct RowsButtons: View {
    @Environment(MixModel.self) private var mix
    let model: BrowserPaneModel
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let ui = mix.prefs.ui, two = model.twoText(ui), detail = model.showsDetail(ui)
        let side = model === browser.paneA ? "A" : "B"
        HStack(spacing: 4.z) {
            Button { model.twoLine = !two } label: {
                Text(two ? "☰" : "≡").font(Theme.mono(13.z)).foregroundStyle(two ? Theme.bone : Theme.muted)
            }
            .buttonStyle(.borderless)
            .help(two ? "Zeilen einzeilig (eine Spalte je Feld)" : "Zeilen zweizeilig: Titel · Artist, darunter Kommentar · Tags · Label")
            .background(UITestMark(name: "rows \(side)"))
            Button { model.detailBar = !detail } label: {
                Text("▭").font(Theme.mono(13.z)).foregroundStyle(detail ? Theme.bone : Theme.muted)
            }
            .buttonStyle(.borderless)
            .help("Detailleiste unter der Liste ein/aus")
            .background(UITestMark(name: "detail \(side)"))
        }
    }
}

/// ◆ UNGESPIELT: gespielte Tracks ausblenden (gilt für beide Bereiche, gleiche Einstellung wie ⌘, -> BROWSER)
struct UnplayedChip: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        DeckButton(title: "UNGESPIELT", active: mix.prefs.ui.hidePlayedTracks) { mix.prefs.ui.hidePlayedTracks.toggle() }.helpInfo("browser.played")
            .help("Gespielte Tracks ausblenden: Collection, Playlists, Smartlists, Ordner, Suche – History, Running Tracks und Preparation zeigen sie weiter. Auch ⌘, → Browser, Menü Browser")
            .background(UITestMark(name: "unplayed"))
    }
}

/// Filter „passt zum Master“: an zeigt er den Bezug (hörbarer Key, Tempo) – eigene Ansicht, nur sie hängt dann am Tempo
struct MatchChip: View {
    @Environment(MixModel.self) private var mix
    let model: BrowserPaneModel

    var body: some View {
        let on = model.matching
        let ref = on ? mix.harmonyKey.map(Track.openKey(code:)) ?? "–" : ""
        let bpm = on && mix.harmonyBPM > 0 ? String(format: " %.1f", mix.harmonyBPM) : ""
        let groove = on ? [MatchRule.Groove.off: "", .similar: " ≈", .complement: " ⇄"][mix.prefs.ui.match.groove] ?? "" : ""
        let chosen = mix.prefs.ui.matchDecks.sorted().map { deckLetters[$0] }.joined(separator: "+")
        let deckText = on && !chosen.isEmpty ? " \(chosen):" : ""
        VStack(alignment: .leading, spacing: 1.z) {
            MatchDeckTiles()
            DeckButton(title: String(localized: "◆ PASST") + (on ? " ·\(deckText) \(ref)\(bpm)\(groove)" : ""), active: on, verbatim: true) { model.matching.toggle() }.helpInfo("browser.matching")
            .help("Nur Tracks, die zum Master passen: Key (gleich, ±1, Relativ), Tempo im Fenster, optional Tag-Gruppen (≈ ähnlich, ⇄ ergänzend) – einstellbar unter ⌘, → Browser")
        }
    }
}

/// Kacheln über ◆ PASST: AUTO (spielender Master, sonst Fokus-Deck) oder feste Decks, mehrere = Track muss zu allen passen.
/// Hell = Deck spielt, gefüllt = gewählt
struct MatchDeckTiles: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let sel = mix.prefs.ui.matchDecks, n = max(2, mix.prefs.ui.deckCount)
        HStack(spacing: 1.z) {
            tile("AUTO", on: sel.isEmpty, playing: false) { mix.prefs.ui.matchDecks = [] }
                .help("Bezug: spielendes Master-Deck, sonst das Fokus-Deck")
            ForEach(0..<n, id: \.self) { d in
                tile(deckLetters[d], on: sel.contains(d), playing: mix.deck(d).playing) {
                    var s = Set(sel)
                    if s.contains(d) { s.remove(d) } else { s.insert(d) }
                    mix.prefs.ui.matchDecks = s.sorted()
                }
                .help("Bezug Deck \(deckLetters[d]) – mehrere Decks: Track muss zu allen passen")
            }
        }
    }

    private func tile(_ t: String, on: Bool, playing: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: t)
                .font(Theme.label(7.5.z, .bold))
                .frame(minWidth: 11.z)
                .frame(height: 9.z)
                .padding(.horizontal, 2.z)
                .foregroundStyle(on ? Theme.void : playing ? Theme.bone : Theme.muted)
                .background(Rectangle().fill(on ? Theme.state.opacity(0.85) : Theme.void))
                .overlay(Rectangle().stroke(on ? Theme.state : playing ? Theme.bone.opacity(0.6) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Suchfeld eines Bereichs: Text sofort im Feld, in die Liste nach 0,15 s Tipp-Pause (leer und ⏎ sofort). Jede neue
/// Suche filtert im Hintergrund und lädt die Tabelle neu (~7 ms Hauptthread) – schnelles Tippen kostet so einen
/// Neuaufbau statt einen je Taste
struct SearchField: View {
    @Bindable var model: BrowserPaneModel
    @State private var text = ""
    @State private var pending: DispatchWorkItem?

    var body: some View {
        TextField("SUCHEN", text: $text)
            .onSubmit { apply(text) }
            .onAppear { text = model.search }
            // von außen gesetzt (Favoriten, Sitzung): ins Feld
            .onChange(of: model.search) { _, s in if s != text { pending?.cancel(); text = s } }
            .onChange(of: text) { _, s in
                pending?.cancel()
                guard s != model.search else { return }
                if s.isEmpty { apply(s); return }
                let w = DispatchWorkItem { MainActor.assumeIsolated { apply(s) } }
                pending = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
            }
    }

    private func apply(_ s: String) {
        pending?.cancel()
        if model.search != s { model.search = s }
    }
}

/// Alle Tags der aktuellen Quelle (aus Kommentar 2) mit Anzahl – Klick filtert. Mit Gruppen (⌘, → TAGS) eine Spalte
/// je Gruppe (Marker im Kopf, Klick = Tracks mit dieser Gruppe), dann Rollen, dann Tags ohne Gruppe.
struct TagPicker: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HistoryStore.self) private var history
    @Bindable var model: BrowserPaneModel
    let separators: String
    @State private var filter = ""
    @Environment(MixModel.self) private var mix
    private var ui: UIPrefs { mix.prefs.ui }

    /// Spalte: Gruppe (nil = ohne), Kopf, Tags nach Anzahl
    struct Column: Identifiable {
        let group: String?
        let title: String
        var count = 0
        var tags: [(tag: String, n: Int)] = []
        var id: String { group ?? "" }
    }

    /// Spalten aus den Tracks: je Tag die häufigste Gruppe, Gruppen nach ihrer mittleren Stelle im Text
    static func columns(_ tracks: [Track], separators: String, ui: UIPrefs) -> [Column] {
        var counts: [String: Int] = [:], groupOf: [String: [String: Int]] = [:]
        var markerN: [String: Int] = [:], markerPos: [String: Int] = [:]
        for t in tracks {
            let e = BrowserPaneModel.tagIndex.entry(t.comment2, separators: separators)
            for (i, tag) in e.tags.enumerated() {
                counts[tag, default: 0] += 1
                guard ui.tagGroups, let g = e.groups[i] else { continue }
                if g == tag { markerN[g, default: 0] += 1; markerPos[g, default: 0] += i } else { groupOf[tag, default: [:]][g, default: 0] += 1 }
            }
        }
        func title(_ g: String?) -> String {
            guard let g else { return String(localized: "OHNE GRUPPE") }
            if g == TagGroups.role { return String(localized: "ROLLE") }
            return ui.tagGroupNames[g].map { "\($0) · \(g)" } ?? g
        }
        var cols: [String: Column] = [:]
        for (tag, n) in counts where markerN[tag] == nil {
            let g = groupOf[tag]?.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
            cols[g ?? "", default: Column(group: g, title: title(g))].tags.append((tag, n))
        }
        for (g, n) in markerN { cols[g, default: Column(group: g, title: title(g))].count = n }
        let order = markerN.keys.sorted { Double(markerPos[$0]!) / Double(markerN[$0]!) < Double(markerPos[$1]!) / Double(markerN[$1]!) }
        return (order + [TagGroups.role, ""]).compactMap { k in
            guard var c = cols[k] else { return nil }
            c.tags.sort { $0.n == $1.n ? $0.tag < $1.tag : $0.n > $1.n }
            return c
        }
    }

    var body: some View {
        let cols = Self.columns(model.base(from: store, history: history), separators: separators, ui: ui)
        let grouped = cols.contains { $0.group != nil }
        let tf = model.tagFilter
        VStack(alignment: .leading, spacing: 6.z) {
            Text("TAGS · KOMMENTAR 2").font(Theme.label(12.z, .bold))
            Text("trennzeichen: '\(separators)' (einstellbar unter ⌘, → BROWSER → Tags)").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
            Text("klick = filter · ⌥-klick = ausschließen · auch in der liste").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
            TextField("FILTERN", text: $filter).textFieldStyle(.plain).font(Theme.mono(11.z))
                .padding(4.z).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            if grouped {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10.z) {
                        ForEach(cols) { c in column(c, tf).frame(width: 150.z) }
                    }
                }
                .frame(height: 340.z)
            } else {
                ScrollView { rows(cols.first?.tags ?? [], group: nil, tf) }.frame(height: 320.z)
            }
            if !tf.isEmpty {
                HStack {
                    DeckButton(title: "✕ TAGS") { model.clearTags() }
                    DeckButton(title: "ALS SMARTLIST") {
                        let inc = model.tags.sorted(), exc = model.excludedTags.sorted()
                        let rules = inc.map { SmartRule(.tag, .contains, $0) } + exc.map { SmartRule(.tag, .notContains, $0) }
                        let it = store.addOwn(.smartlist, into: nil, name: (inc + exc.map { "!" + $0 }).joined(separator: " + "),
                                              rules: SmartRules(rules: rules))
                        model.source = .own(OwnRef(it))
                        model.clearTags()
                    }
                    .help("Smartlist aus den gewählten Tags anlegen (alle müssen passen, ausgeschlossene nicht)")
                }
            }
        }
        .padding(10.z)
        .frame(width: grouped ? min(CGFloat(cols.count), 5) * 160.z + 20.z : 320.z)
        .background(Theme.chitin)
    }

    private func column(_ c: Column, _ tf: TagFilter) -> some View {
        VStack(alignment: .leading, spacing: 4.z) {
            if let g = c.group, g != TagGroups.role {
                // Marker = Tag: Klick filtert auf Tracks mit dieser Gruppe
                tagButton(g, n: c.count, group: g, tf, title: c.title)
            } else {
                Text(c.title).font(Theme.label(11.z, .bold)).foregroundStyle(Theme.muted).padding(.vertical, 1.z)
            }
            ScrollView { rows(c.tags, group: c.group, tf) }
        }
    }

    private func rows(_ tags: [(tag: String, n: Int)], group: String?, _ tf: TagFilter) -> some View {
        VStack(alignment: .leading, spacing: 2.z) {
            ForEach(tags.filter { filter.isEmpty || $0.tag.localizedCaseInsensitiveContains(filter) }, id: \.tag) { t in
                tagButton(t.tag, n: t.n, group: group, tf)
            }
        }
    }

    private func tagButton(_ k: String, n: Int, group: String?, _ tf: TagFilter, title: String? = nil) -> some View {
        let mark = tf.mark(k)
        return Button {
            model.toggleTag(k, exclude: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
        } label: {
            HStack {
                Text(mark == .include ? "■" : mark == .exclude ? "⊘" : "□")
                    .foregroundStyle(mark == .none ? Theme.muted : Theme.state)
                TagChip(tag: title ?? k, mark: mark, style: TagChipStyle.of(k, group: group, ui))
                Spacer(minLength: 2.z)
                Text("\(n)").foregroundStyle(Theme.muted)
            }
            .font(title == nil ? Theme.mono(11.z) : Theme.label(11.z, .bold))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Baum: Collection, Preparation (+ Archiv), History (+ Archiv), Musik-Ordner, PLAYLISTS (eigene + Collection).
struct SourceTree: View {
    @Binding var selection: BrowserSource
    @State private var treeUI = PlaylistTreeUI()

    // Zeilen in eigenen Ansichten: ein Quellenwechsel wertet nur die Auswahl der Liste neu aus, nicht alle Zeilen
    // (Baum bleibt auch ausgeblendet in der Ansicht, siehe BrowserPane)
    var body: some View {
        // Markiert ist immer die Quelle; ⌘ / ⇧ Klick nimmt Einträge dazu oder weg (Menü „Reset Played State“ gilt für alle)
        List(selection: Binding<Set<BrowserSource>>(get: { treeUI.marked.contains(selection) ? treeUI.marked : [selection] },
                                                    set: { pick($0) })) {
            SourceTreeFixed()
            MusicFolderTree(selection: $selection)
            ExplorerTree(selection: $selection)
            PlaylistsSection(selection: $selection)
        }
        .listStyle(.sidebar)
        .background(TreeDropHook(regions: treeUI.regions))   // Ablage aus Tabelle und Baum: vor der Liste, nur während eines Zugs   // Ablage aus Tabelle und Baum: vor der Liste, nur während eines Zugs
        .scrollContentBackground(.hidden)
        .background(Theme.chitin)
        .environment(treeUI)
        .modifier(PlaylistTreeDialogs(ui: treeUI, selection: $selection))
        .onChange(of: selection) { if !treeUI.marked.contains(selection) { treeUI.marked = [selection] } }
    }

    /// Auswahl aus der Liste übernehmen: ein Eintrag = die Quelle; bei mehreren nimmt die Quelle den neu dazugekommenen
    /// Eintrag (⌘-Klick), bleibt sie bei einem Bereich (⇧-Klick) stehen, wenn sie noch dabei ist
    private func pick(_ new: Set<BrowserSource>) {
        guard !new.isEmpty else { return }   // ⌘-Klick auf den einzigen Eintrag lässt die Quelle stehen
        let primary = Self.primary(new, marked: treeUI.marked, selection: selection)
        treeUI.marked = new
        if let primary, primary != selection { selection = primary }
    }

    /// Quelle nach einer Auswahl im Baum (pur): ein Eintrag = er; mehrere: der neu dazugekommene (⌘-Klick), bei einem
    /// Bereich (⇧-Klick) bleibt die Quelle, wenn sie dabei ist
    nonisolated static func primary(_ new: Set<BrowserSource>, marked: Set<BrowserSource>, selection: BrowserSource) -> BrowserSource? {
        guard !new.isEmpty else { return nil }
        if new.count == 1 { return new.first }
        let added = new.subtracting(marked)
        if added.count == 1 { return added.first }
        return new.contains(selection) ? selection : new.first
    }
}

/// Collection, Preparation, History
struct SourceTreeFixed: View, SourceMenus {
    @Environment(LibraryStore.self) var store
    @Environment(HistoryStore.self) var history
    @Environment(MixModel.self) private var decks
    @Environment(PlaylistTreeUI.self) private var ui

    var body: some View {
        row("≣", "TRACK COLLECTION").tag(BrowserSource.collection).helpInfo("tree.collection")
            .favoriteDrag { BrowserFavorite.source(.collection, store: store) }
            .contextMenu {
                exportMenu(.collection)
                Button("Collection prüfen …") { ConsistencyWindow.show(store: store) }
                Button("Reset Played State") { history.resetPlayed() }
                Button("Collection neu laden") { store.load(store.sourceURL ?? LibraryStore.defaultNML) }
                Toggle("Gespielte Tracks ausblenden", isOn: Binding(get: { decks.prefs.ui.hidePlayedTracks }, set: { decks.prefs.ui.hidePlayedTracks = $0 }))
                OverviewMenuButton { store.tracks }
                AnalysisMenuButtons { store.tracks }
                ImportMenuButton(source: "Track Collection") { store.tracks }
                KeyProfileMenuButtons { store.tracks }
                CloudMenuButton(label: "Track Collection") { store.tracks }
            }
        row("▶", "RUNNING TRACKS").tag(BrowserSource.running)
            .favoriteDrag { BrowserFavorite.source(.running, store: store) }
        if DAWBridgeModel.shared.connected || !DAWBridgeModel.shared.clips.isEmpty {
            row("◇", "DAW").tag(BrowserSource.daw)
                .help("Spielende und ausgewählte Audio-Clips der DAW (Remote Script); Doppelklick lädt mit dem Grid aus den Warp-Markern")
        }
        if !store.cuts.isEmpty {
            row("◫", "CUTS").tag(BrowserSource.cuts)
                .help("Geschnittene Dateien (Wellenform: ⌃ + Ziehen markiert, Rechtsklick schneidet)")
                .contextMenu { OverviewMenuButton { store.cuts } }
            if !store.toolLoops.isEmpty {
                row("↻", "TOOL-LOOPS").tag(BrowserSource.toolLoops)
                    .help("Tool-Loops (EDIT-Modus: TOOL 2 · 4 · 8 · 16), Tag tool-loop")
                    .contextMenu { OverviewMenuButton { store.toolLoops } }
            }
        }
        if RipChecks.shared.revision >= 0, RipChecks.shared.openCount > 0 {
            row("◆", "ZU BEARBEITEN").tag(BrowserSource.ripTodo)
                .help("Tracks mit offenem Befund der Rip-Prüfung (Stille, fremder Anfang oder fremdes Ende, Grid prüfen)")
                .contextMenu { AnalysisMenuButtons { store.tracks(for: .ripTodo) } }
        }
        if store.missingTracks.count > 0 {
            row("✕", "MISSING \(store.missingTracks.count)").tag(BrowserSource.missing)
                .help("Tracks ohne Datei: Cloud „fehlt“ oder nicht auf der Platte. → TIDAL im Kopf: Playlist bei TIDAL")
                .contextMenu { exportMenu(.missing); OverviewMenuButton { store.tracks(for: .missing) } }
        }
        row("▤", "PREPARATION").tag(BrowserSource.preparation).helpInfo("tree.preparation")
            .favoriteDrag { BrowserFavorite.source(.preparation, store: store) }
            .background(ui.prepTargeted ? Theme.chitinRaised : .clear)
            .treeDropZone(ui.regions, name: "tree drop prep", highlight: { ui.prepTargeted = $0 },
                          accepts: { $0.contains { TrackDrag.key($0) != nil } }) { strings in
                let keys = strings.compactMap(TreeDrag.track).filter { store.track($0) != nil }
                guard !keys.isEmpty else { return false }
                store.appendToPreparation(keys)
                return true
            }
            .contextMenu {
                exportMenu(.preparation)
                resetPlayedButton(.preparation, marked: ui.marked)
                OverviewMenuButton { store.tracks(for: .preparation) }
                AnalysisMenuButtons { store.tracks(for: .preparation) }
                CloudMenuButton(label: "Preparation") { store.tracks(for: .preparation) }
            }
        DisclosureGroup {
            ForEach(history.prepArchive) { s in
                row("▤", Theme.dateTimeFormat.string(from: s.date)).tag(BrowserSource.prepArchive(s))
                    .contextMenu { exportMenu(.prepArchive(s)) }
            }
        } label: { row("▸", String(localized: "PREPARATION ARCHIV")) }
        row("◷", "HISTORY").tag(BrowserSource.historyLive).helpInfo("tree.history")
            .favoriteDrag { BrowserFavorite.source(.historyLive, store: store) }
            .contextMenu { exportMenu(.historyLive) }
        DisclosureGroup {
            ForEach(history.archive) { s in
                row(s.source == .external ? "◷" : "◴", s.label ?? Theme.dateTimeFormat.string(from: s.date)).tag(BrowserSource.history(s))
                    .contextMenu { exportMenu(.history(s)) }
            }
        } label: { row("▸", String(localized: "HISTORY ARCHIV")) }
    }
}

/// Zeilen und Kontextmenüs des Baums
@MainActor
protocol SourceMenus {
    var store: LibraryStore { get }
    var history: HistoryStore { get }
}

extension SourceMenus {
    /// Kontextmenü „Exportieren“ für eine Quelle
    @ViewBuilder func exportMenu(_ src: BrowserSource) -> some View {
        Menu("Exportieren") {
            Button("NML …") { export(.nml, src) }
            Button("M3U …") { export(.m3u, src) }
            Button("Ordner mit Audiodateien …") { export(.folder, src) }
        }
    }

    func export(_ f: PlaylistExport.Format, _ src: BrowserSource) {
        let tracks: [Track]
        switch src {
        case .historyLive: tracks = history.live.compactMap { store.byKey[$0.key] }
        case let .history(s): tracks = history.entries(s).compactMap { store.byKey[$0.key] }
        case let .prepArchive(s): tracks = history.prepKeys(s).compactMap { store.byKey[$0] }
        default: tracks = store.tracks(for: src)
        }
        PlaylistExport.run(f, name: src.title, tracks: tracks, store: store)
    }

    /// Tracks eines Knotens, Ordner mit allen Unterknoten
    func nodeTracks(_ n: PlaylistNode) -> [Track] {
        n.kind == .folder ? n.children.flatMap(nodeTracks) : store.tracks(for: .node(n))
    }

    /// Track-Schlüssel eines Baum-Eintrags (Ordner mit allen darunter) für „Reset Played State“
    func treeKeys(_ src: BrowserSource) -> Set<String> {
        switch src {
        case .preparation: Set(store.preparation)
        case let .own(r): Set(store.ownTracksDeep(r.id).map(\.key))
        case let .node(n): Set(nodeTracks(n).map(\.key))
        case let .folder(p): Set(store.folders.tracks(in: p, recursive: true, library: store).map(\.key))
        default: Set(store.tracks(for: src).map(\.key))
        }
    }

    /// „Reset Played State“ an einem Baum-Eintrag: sind mehrere markiert und dieser ist dabei, gilt es für alle markierten
    @ViewBuilder func resetPlayedButton(_ src: BrowserSource, marked: Set<BrowserSource>) -> some View {
        Button("Reset Played State") {
            let srcs = marked.contains(src) ? marked : [src]
            history.resetPlayed(keys: srcs.reduce(into: Set<String>()) { $0.formUnion(treeKeys($1)) })
        }
    }

    func icon(_ n: PlaylistNode) -> String {
        switch n.kind {
        case .folder: OwnGlyph.folder
        case .playlist: OwnGlyph.playlist
        case .smartlist: OwnGlyph.smartlist
        }
    }

    func row(_ glyph: String, _ name: String) -> some View {
        HStack(spacing: 6.z) {
            Text(glyph).font(Theme.mono(11.z)).foregroundStyle(Theme.muted).frame(width: 12.z)
            Text(name).font(Theme.mono(11.z)).foregroundStyle(Theme.bone).lineLimit(1)
        }
        .frame(minHeight: 20.z)   // Zeilenhöhe der Seitenleiste mit dem Zoom (100 %: 28 pt)
    }
}

/// History-Ansicht: Startzeit, Deck, Dauer.
struct HistoryTable: View {
    @Environment(LibraryStore.self) private var store
    @Environment(MixModel.self) private var mix
    let entries: [HistoryEntry]
    @Bindable var model: BrowserPaneModel
    @State private var selection: Set<Int> = []

    struct Row: Identifiable {
        let id: Int
        let e: HistoryEntry
    }

    var body: some View {
        let rows = entries.enumerated().map { Row(id: $0.offset, e: $0.element) }
        Table(rows, selection: $selection) {
            TableColumn("#") { (r: Row) in Text("\(r.id + 1)") }.width(28.z)
            TableColumn("Start") { (r: Row) in Text(Theme.timeFormat.string(from: r.e.start)) }.width(64.z)
            TableColumn("Deck") { (r: Row) in Text(deckLetters[max(0, min(3, r.e.deck))]) }.width(36.z)
            TableColumn("Artist") { (r: Row) in Text(r.e.artist) }
            TableColumn("Title") { (r: Row) in Text(r.e.title) }
            TableColumn("BPM") { (r: Row) in Text(r.e.bpm > 0 ? String(format: "%.1f", r.e.bpm) : "") }.width(48.z)
            TableColumn("Key") { (r: Row) in Text(r.e.keyText) }.width(36.z)
            TableColumn("Dauer") { (r: Row) in Text(Theme.time(r.e.duration)) }.width(48.z)
        }
        .font(Theme.mono(11.z))
        .scrollContentBackground(.hidden)
        .background(Theme.void)
        .contextMenu(forSelectionType: Int.self) { ids in
            ForEach(0..<4, id: \.self) { n in
                Button("In Deck \(deckLetters[n]) laden") { load(ids, n) }
            }
            Button("An Preparation anhängen") {
                store.appendToPreparation(ids.sorted().filter { $0 < entries.count }.map { entries[$0].key })
            }
        } primaryAction: { ids in load(ids, mix.focusedDeck) }
    }

    private func load(_ ids: Set<Int>, _ d: Int) {
        guard let i = ids.first, i < entries.count, let t = store.byKey[entries[i].key] else { return }
        mix.load(t, deck: d)
    }
}

struct TrackTable: View {
    @Environment(LibraryStore.self) private var store
    @Environment(BrowserState.self) private var browser
    @Environment(MixModel.self) private var decks
    @Environment(HistoryStore.self) private var history
    @Bindable var model: BrowserPaneModel
    /// nur Selbsttest-Bilder: feste Zeilen statt der Liste des Bereichs
    var rows: [Track]? = nil
    @State private var table = TrackTableController()
    @State private var inlineCtl = InlineEditController()
    @State private var rowBand = PreviewRowController()

    var body: some View {
        let ui = decks.prefs.ui
        // Live-Lesbarkeit: einzeilig, ohne Vorschau (Band und Spalte aus), eigene Spalten und Schrift in der Tabelle
        let live = ui.liveListOn(live: decks.live)
        let lui: UIPrefs = { var u = ui; if live { u.previewMode = .off }; return u }()
        // stößt die Liste an (Hintergrund); die Tabelle zeigt immer `model.shown`, neue Listen kommen über `onList`
        let _ = rows == nil ? model.list(from: store, history: history, separators: ui.tagSeparators, hidePlayed: ui.hidePlayedTracks) : []
        // Vorschau-Bilder in Zellen hängen am Übersichten-Zähler, das Band (ganze Zeile) zeichnet PreviewRowLayer
        let tick = lui.previewMode == .column || lui.previewMode == .behindTitle ? Overviews.shared.tick : 0
        let look = TrackTableController.Look(ui: lui, zoom: UIZoom.shared.factor, filter: model.tagFilter, inline: model.inline,
                                             played: history.played, cloud: CloudLibrary.shared.revision, rip: RipChecks.shared.revision, tick: tick,
                                             preview: lui.previewMode == .column || lui.previewMode == .behindTitle ? decks.previewing?.key : nil,
                                             twoText: model.twoText(ui) && !live, liveList: live)
        TrackTableView(controller: table, look: look, selection: model.selection, sort: model.sortOrder) { table in
                table.model = model
                table.fixedRows = rows
                model.onList = { [weak table] in table?.listArrived() }
                model.onDetail = { [weak table] in table?.refreshDetail() }
                table.store = store
                table.history = history
                table.mix = decks
                table.inline = inlineCtl
                inlineCtl.model = model
                inlineCtl.store = store
                inlineCtl.tableView = table.table
                inlineCtl.tableCtl = table
                inlineCtl.rows = { [table] in table.shownRows }
                inlineCtl.writeBack = { [decks] in decks.prefs.ui.writeCollection }
                // Tag-Chip unter dem Klick, nur ganz sichtbare (abgeschnittene enden in „…“)
                inlineCtl.chipAt = { [decks] t, x, width in
                    let tags = BrowserPaneModel.tagIndex.entry(t.comment2, separators: decks.prefs.ui.tagSeparators).shown(groups: decks.prefs.ui.tagGroups).tags
                    return TagChipsText.spans(tags: tags, .of(decks.prefs.ui)).firstIndex { $0.contains(x) && $0.upperBound <= width }.map { tags[$0] }
                }
                inlineCtl.textTop = { [weak table] in table?.bandTop }
                rowBand.inline = inlineCtl
                rowBand.rows = { [weak table] in table?.shownRows ?? [] }
                rowBand.bandTop = { [weak table] in table?.bandTop }
                table.onReload = { [rowBand] in rowBand.refresh() }
            }
            .background(PreviewRowLayer(controller: rowBand, mix: decks, on: ui.previewMode == .fullRow && !live))
            .onAppear { inlineCtl.install() }
            .onDisappear { inlineCtl.uninstall(); rowBand.remove(); table.detach(); table.flushLayout() }
            .onChange(of: model.selection) { browser.activePaneID = model.id }
            .onChange(of: browser.scrollRequest?.track) {
                if let r = browser.scrollRequest, r.pane == model.id { table.scroll(to: r.track) }
            }
    }
}
