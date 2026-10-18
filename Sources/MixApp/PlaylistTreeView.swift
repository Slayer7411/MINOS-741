import SwiftUI
import AppKit
import MixCore

/// Zeichen im Baum (monochrom, IBM Plex Mono): Ordner, Playlist, Smartlist – eigene und aus der Collection gleich
enum OwnGlyph {
    static let folder = "▸"
    static let playlist = "≡"
    static let smartlist = "◇"

    static func of(_ k: PlaylistItem.Kind) -> String {
        switch k {
        case .folder: folder
        case .playlist: playlist
        case .smartlist: smartlist
        }
    }
}

/// Eintrag des eigenen Baums ziehen: auf einen Ordner (hinein), auf einen Eintrag (davor), auf PLAYLISTS (nach oben),
/// auf einen Favoriten-Platz (belegen)
@MainActor
enum TreeDrag {
    static let prefix = "minos741-item:"

    static func provider(_ id: UUID, favorite: BrowserFavorite?) -> NSItemProvider {
        _ = FavoriteDrag.provider(favorite)   // Favoritenleiste liest den Favoriten von dort
        TreeDragGate.beginTree()              // Ablage-Schicht des Baums übernimmt, sobald mit gedrückter Taste gezogen wird
        return NSItemProvider(object: (prefix + id.uuidString) as NSString)
    }

    static func item(_ s: String) -> UUID? { s.hasPrefix(prefix) ? UUID(uuidString: String(s.dropFirst(prefix.count))) : nil }
    static func track(_ s: String) -> String? { TrackDrag.key(s) }
}

/// Zug von Tracks (Tabelle) oder Baum-Einträgen läuft: nur dann nimmt die Ablage-Schicht des Baums den Zeiger an. Sonst
/// bleibt sie unsichtbar, damit Klicks, Rechtsklick, Scrollen und das Ziehen innerhalb der Liste unverändert gehen
@MainActor
enum TreeDragGate {
    static var active = false
    /// Baum-Eintrag angefasst: aktiv erst, wenn mit gedrückter Taste gezogen wird
    static var pendingTree = false
    /// Taste gehalten (beim Ziehen immer); der Selbsttest setzt es
    static var buttonHeld: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    private static var monitor: Any?

    /// Ziehen aus der Tabelle beginnt
    static func begin() { install(); active = true; pendingTree = false }
    static func beginTree() { install(); pendingTree = true }
    /// Ende (Ablegen, Abbruch, Klick)
    static func end() { active = false; pendingTree = false }

    /// Texte des Zugs in Reihenfolge
    static func strings(_ pb: NSPasteboard) -> [String] { (pb.pasteboardItems ?? []).compactMap { $0.string(forType: .string) } }

    /// nur Tracks und Baum-Einträge (Reordering der Liste und fremde Texte bleiben bei SwiftUI bzw. werden abgelehnt)
    static func carriesItems(_ pb: NSPasteboard) -> Bool {
        strings(pb).contains { TrackDrag.key($0) != nil || TreeDrag.item($0) != nil }
    }

    private static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp]) { e in
            MainActor.assumeIsolated {
                if e.type == .leftMouseDragged {
                    if pendingTree { pendingTree = false; active = true }
                } else {
                    end()   // vor jedem Klick aus: ein Klick nach dem Zug trifft wieder die Liste
                }
            }
            return e
        }
    }
}

/// Ablage-Schicht über der Baum-Liste: AppKit fände sonst die Zeile der SwiftUI-Liste (die nur ihre eigene Umordnung
/// annimmt). Liegt als Geschwister vor der Liste im Hosting-View der Seitenleiste (Größe = ganze Seitenleiste). Nur während
/// eines Zugs unter dem Zeiger sichtbar für Ablage (`TreeDragGate`), sonst transparent; Ziel ist die Zone darunter
final class TreeDropView: NSView {
    weak var regions: DropRegions?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard TreeDragGate.active, TreeDragGate.buttonHeld(), bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { update(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { update(s) }

    override func draggingExited(_ s: NSDraggingInfo?) {
        regions?.clear()
        TreeDragGate.end()
    }

    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        regions?.clear()
        TreeDragGate.end()
        return regions?.zone(at: s.draggingLocation)?.perform(s.draggingPasteboard) ?? false
    }

    private func update(_ s: NSDraggingInfo) -> NSDragOperation {
        guard let regions, TreeDragGate.carriesItems(s.draggingPasteboard) else { return [] }
        regions.highlight(at: s.draggingLocation)
        guard let z = regions.zone(at: s.draggingLocation), z.accepts(s.draggingPasteboard) else { return [] }
        return .copy
    }
}

/// Hängt die Ablage-Schicht (`TreeDropView`) an die Seitenleiste: der NSViewRepresentable liegt in der Liste, die Schicht
/// geht an das Hosting-View darüber (vor die Liste gestellt, ganze Fläche)
struct TreeDropHook: NSViewRepresentable {
    let regions: DropRegions

    final class V: NSView {
        weak var overlay: TreeDropView?
        var regions: DropRegions?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            var host: NSView? = superview
            while let h = host, !String(describing: Swift.type(of: h)).contains("HostingView") { host = h.superview }
            guard let host else { return }
            let ov = overlay ?? TreeDropView()
            if overlay == nil { ov.registerForDraggedTypes([.string]) }
            ov.regions = regions
            ov.frame = host.bounds
            ov.autoresizingMask = [.width, .height]
            if ov.superview !== host {
                ov.removeFromSuperview()
                host.addSubview(ov)   // nach allen bisherigen Geschwistern: vor der Liste
            }
            overlay = ov
        }

        func detach() {
            overlay?.removeFromSuperview()
            overlay = nil
        }
    }

    func makeNSView(context: Context) -> V { V() }

    func updateNSView(_ v: V, context: Context) {
        v.regions = regions
        v.overlay?.regions = regions
        v.attach()
    }

    static func dismantleNSView(_ v: V, coordinator: ()) { v.detach() }
}

extension View {
    /// Ablagezone der Baum-Ebene (Zeile, Knopf): Tracks und Baum-Einträge; `accepts`/`perform` bekommen deren Texte
    func treeDropZone(_ regions: DropRegions, name: String = "", highlight: @escaping @MainActor (Bool) -> Void,
                      accepts: @escaping @MainActor ([String]) -> Bool, perform: @escaping @MainActor ([String]) -> Bool) -> some View {
        background(DropZone(regions: regions, name: name,
                            accepts: { accepts(TreeDragGate.strings($0)) },
                            perform: { perform(TreeDragGate.strings($0)) },
                            highlight: highlight))
    }
}

private struct TreeProviderBox: @unchecked Sendable { let provider: NSItemProvider }

/// Zustand der Dialoge des Baums (Umbenennen, Löschen, Smartlist-Editor), Auf-/Zu der Ordner, Ziel beim Ziehen
@MainActor @Observable
final class PlaylistTreeUI {
    var rootOpen = true
    var collapsed: Set<UUID> = []
    var renaming: PlaylistItem?
    var renameText = ""
    var deleting: PlaylistItem?
    var editing: SmartlistDraft?
    var dropTarget: UUID?
    /// PLAYLISTS selbst als Ziel
    var rootTargeted = false
    /// PREPARATION als Ziel
    var prepTargeted = false
    /// Ablagezonen der Baum-Ebene (Zeilen, PREPARATION), von der Ablage-Schicht über der Liste befragt
    @ObservationIgnored let regions = DropRegions()
    /// Mehrfachauswahl im Baum (⌘ / ⇧ Klick); die Quelle des Browsers ist der zuletzt angeklickte Eintrag
    var marked: Set<BrowserSource> = []

    func rename(_ i: PlaylistItem) { renameText = i.name; renaming = i }
}

/// Ein Baum „PLAYLISTS“: eigene Ordner / Playlists / Smartlists (änderbar) und darunter die der Collection-Datei
/// (nur lesen, mit ihrer Ordnerstruktur; den eigenen Spiegel `MINOS-741/Playlists` blendet der Baum aus)
struct PlaylistsSection: View, SourceMenus {
    @Environment(LibraryStore.self) var store
    @Environment(HistoryStore.self) var history
    @Environment(PlaylistTreeUI.self) private var ui
    @Environment(MixModel.self) private var mix
    @Binding var selection: BrowserSource

    var body: some View {
        @Bindable var ui = ui
        DisclosureGroup(isExpanded: $ui.rootOpen) {
            OwnItemsView(items: store.playlists.items, selection: $selection)
            OutlineGroup(store.root.visibleChildren ?? [], children: \.visibleChildren) { node in
                row(icon(node), node.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(ui.dropTarget == node.id ? Theme.chitinRaised : .clear)
                    .tag(BrowserSource.node(node))
                    .lineLimit(1)
                    .help(collectionHelp(node))
                    .favoriteDrag { BrowserFavorite.source(.node(node), store: store) }
                    // Playlist der Collection: Tracks ablegen (wird in die Datei geschrieben); Smartlist: Hinweis
                    .treeDropZone(ui.regions, name: "collection drop \(node.name)", highlight: { on in
                        ui.dropTarget = on ? node.id : (ui.dropTarget == node.id ? nil : ui.dropTarget)
                    }, accepts: { strings in
                        node.kind != .folder && strings.contains { TrackDrag.key($0) != nil }
                    }) { strings in
                        dropCollection(node, strings)
                    }
                    .contextMenu {
                        resetPlayedButton(.node(node), marked: ui.marked)
                        autoMixMenuButton(.node(node), marked: ui.marked, mix: mix)
                        if node.kind != .folder { exportMenu(.node(node)) }
                        OverviewMenuButton { nodeTracks(node) }
                        AnalysisMenuButtons { nodeTracks(node) }
                        ImportMenuButton(source: node.name) { nodeTracks(node) }
                        CloudMenuButton(label: node.name) { nodeTracks(node) }
                        if node.kind == .playlist {
                            Divider()
                            Button("Als eigene Playlist übernehmen") {
                                let it = store.addOwn(.playlist, into: nil, name: node.name, tracks: node.trackKeys)
                                selection = .own(OwnRef(it))
                            }
                        }
                        if node.kind == .smartlist {
                            Divider()
                            // Regel-Text unverändert als eigene Smartlist (wertet wie in der Collection); die Collection bleibt
                            Button("Bearbeiten … (als eigene Kopie)") {
                                let rule = SmartRules(rules: [SmartRule(.expression, .matches, node.query)])
                                let it = store.addOwn(.smartlist, into: nil, name: node.name, rules: rule)
                                selection = .own(OwnRef(it))
                                ui.editing = SmartlistDraft(edit: it)
                            }
                        }
                    }
            }
        } label: {
            row("▸", "PLAYLISTS").helpInfo("tree.playlists")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(ui.rootTargeted ? Theme.chitinRaised : .clear)
                .contextMenu { PlaylistNewMenu(parent: nil, selection: $selection) }
                .treeDropZone(ui.regions, name: "tree drop", highlight: { ui.rootTargeted = $0 },
                              accepts: { $0.contains { TreeDrag.item($0) != nil || TrackDrag.key($0) != nil } }) { strings in
                    if let id = strings.compactMap(TreeDrag.item).first {
                        store.editPlaylists(String(localized: "Verschieben")) { $0.move(id, into: nil) }
                        return true
                    }
                    let keys = strings.compactMap(TreeDrag.track)
                    guard !keys.isEmpty else { return false }
                    let it = store.addOwn(.playlist, into: nil, tracks: keys)
                    selection = .own(OwnRef(it))
                    return true
                }
                .accessibilityIdentifier("tree.playlists")
        }
    }
}

extension PlaylistsSection {
    /// Hilfetext einer Zeile der Collection: Art, bei Smartlists die Regel (sie wertet die Collection selbst aus)
    func collectionHelp(_ node: PlaylistNode) -> String {
        switch node.kind {
        case .folder: String(localized: "Ordner der Collection (nur lesen)")
        case .playlist: String(localized: "Playlist der Collection · Tracks hierher ziehen (wird in die Collection-Datei geschrieben)")
        case .smartlist: String(localized: "Smartlist der Collection · Regel: \(node.query)")
        }
    }

    /// Ablegen auf eine Playlist der Collection: ans Ende in die Datei. Smartlist: die Tracks kommen über die Regel
    func dropCollection(_ node: PlaylistNode, _ strings: [String]) -> Bool {
        let keys = strings.compactMap(TreeDrag.track)
        guard !keys.isEmpty else { return false }
        if node.kind == .smartlist {
            let msg = String(localized: "Smartlist – Tracks kommen über die Regel (Rechtsklick → Bearbeiten …)")
            store.status = msg
            StatusCenter.post(.info, msg, key: "playlist")
            return true
        }
        store.addToCollectionPlaylist(node.id, keys: keys)
        return true
    }
}

extension PlaylistNode {
    /// Kinder für den Baum: der eigene Spiegel `MINOS-741` (Playlists, Preparation, History) steht schon als eigene
    /// Quellen darüber, er fehlt hier, damit nichts doppelt erscheint
    var visibleChildren: [PlaylistNode]? {
        guard kind == .folder else { return nil }
        guard name == "$ROOT" else { return children }
        return children.filter { !($0.kind == .folder && $0.name == CollectionWriter.ownFolder) }
    }
}

/// Menü „Neu“ an PLAYLISTS und an eigenen Ordnern
struct PlaylistNewMenu: View {
    @Environment(LibraryStore.self) private var store
    @Environment(PlaylistTreeUI.self) private var ui
    let parent: UUID?
    @Binding var selection: BrowserSource

    var body: some View {
        Button("Neue Playlist") {
            let it = store.addOwn(.playlist, into: parent)
            selection = .own(OwnRef(it))
            open(parent)
            ui.rename(it)
        }
        Button("Neue Smartlist …") {
            ui.editing = SmartlistDraft(new: store.playlists.uniqueName(String(localized: "Neue Smartlist"), in: parent), parent: parent)
        }
        Button("Neuer Ordner") {
            let it = store.addOwn(.folder, into: parent)
            open(parent)
            ui.rename(it)
        }
    }

    private func open(_ id: UUID?) {
        ui.rootOpen = true
        if let id { ui.collapsed.remove(id) }
    }
}

/// eigene Einträge einer Ebene (rekursiv)
struct OwnItemsView: View {
    @Environment(PlaylistTreeUI.self) private var ui
    let items: [PlaylistItem]
    @Binding var selection: BrowserSource

    var body: some View {
        ForEach(items) { it in
            if it.kind == .folder {
                DisclosureGroup(isExpanded: Binding(get: { !ui.collapsed.contains(it.id) },
                                                    set: { if $0 { ui.collapsed.remove(it.id) } else { ui.collapsed.insert(it.id) } })) {
                    OwnItemsView(items: it.children, selection: $selection)
                } label: {
                    OwnItemRow(item: it, selection: $selection)
                }
            } else {
                OwnItemRow(item: it, selection: $selection)
            }
        }
    }
}

/// Zeile eines eigenen Eintrags: Auswahl, Rechtsklick, Ziehen, Ablegen (Einträge, Tracks)
struct OwnItemRow: View, SourceMenus {
    @Environment(LibraryStore.self) var store
    @Environment(HistoryStore.self) var history
    @Environment(PlaylistTreeUI.self) private var ui
    @Environment(MixModel.self) private var mix
    let item: PlaylistItem
    @Binding var selection: BrowserSource

    var body: some View {
        let ref = OwnRef(item)
        let src = BrowserSource.own(ref)
        let target = ui.dropTarget == item.id
        row(OwnGlyph.of(item.kind), item.name)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(target ? Theme.chitinRaised : .clear)
            .overlay(alignment: .top) {
                // Eintrag davor einsetzen: Strich über der Zeile (Ordner: Rahmen = hinein)
                if target, item.kind != .folder { Rectangle().fill(Theme.bone.opacity(0.7)).frame(height: 1) }
            }
            .overlay { if target, item.kind == .folder { Rectangle().stroke(Theme.bone.opacity(0.6), lineWidth: 1) } }
            .tag(src)
            .lineLimit(1)
            .help(help)
            .itemProvider {
                let make = { MainActor.assumeIsolated { TreeProviderBox(provider: TreeDrag.provider(item.id, favorite: BrowserFavorite.source(src, store: store))) } }
                return (Thread.isMainThread ? make() : DispatchQueue.main.sync(execute: make)).provider
            }
            .treeDropZone(ui.regions, name: "tree drop", highlight: { on in ui.dropTarget = on ? item.id : (ui.dropTarget == item.id ? nil : ui.dropTarget) },
                          accepts: { strings in
                              strings.contains { TreeDrag.item($0) != nil } || (item.kind == .playlist && strings.contains { TrackDrag.key($0) != nil })
                          }) { drop($0) }
            .contextMenu { menu(src) }
    }

    private var help: String {
        switch item.kind {
        case .folder: String(localized: "Ordner · Einträge hierher ziehen")
        case .playlist: String(localized: "Playlist · Tracks hierher ziehen, Reihenfolge in der Liste per Ziehen, ⌫ entfernt")
        case .smartlist: String(localized: "Smartlist · Rechtsklick → Bearbeiten …")
        }
    }

    private func drop(_ strings: [String]) -> Bool {
        if let id = strings.compactMap(TreeDrag.item).first {
            guard id != item.id else { return false }
            if item.kind == .folder {
                store.editPlaylists(String(localized: "Verschieben")) { $0.move(id, into: item.id) }
                ui.collapsed.remove(item.id)
            } else if case let .some(parent) = store.playlists.parent(of: item.id) {
                let siblings = parent.flatMap { store.playlists.item($0)?.children } ?? store.playlists.items
                let at = siblings.firstIndex { $0.id == item.id }
                store.editPlaylists(String(localized: "Verschieben")) { $0.move(id, into: parent, at: at) }
            }
            return true
        }
        let keys = strings.compactMap(TreeDrag.track)
        guard !keys.isEmpty, item.kind == .playlist else { return false }
        store.addToPlaylist(keys, item.id)
        return true
    }

    @ViewBuilder private func menu(_ src: BrowserSource) -> some View {
        if item.kind == .folder {
            PlaylistNewMenu(parent: item.id, selection: $selection)
            Divider()
        }
        if item.kind == .smartlist {
            Button("Bearbeiten …") { ui.editing = SmartlistDraft(edit: item) }
        }
        Button("Umbenennen …") { ui.rename(item) }
        if item.kind != .folder {
            Button("Duplizieren") {
                guard case let .some(parent) = store.playlists.parent(of: item.id) else { return }
                var copy = item
                copy.id = UUID()
                copy.name = store.playlists.uniqueName(item.name + " " + String(localized: "Kopie"), in: parent)
                store.editPlaylists(String(localized: "Duplizieren")) { $0.insert(copy, into: parent) }
            }
        }
        if item.kind == .smartlist {
            Button("Als Playlist speichern") {
                let keys = store.ownTracks(item.id).map(\.key)
                guard case let .some(parent) = store.playlists.parent(of: item.id) else { return }
                let it = store.addOwn(.playlist, into: parent, name: item.name, tracks: keys)
                selection = .own(OwnRef(it))
            }
        }
        MoveMenu(item: item)
        Button("Löschen …") { ui.deleting = item }
        Divider()
        resetPlayedButton(src, marked: ui.marked)
        autoMixMenuButton(src, marked: ui.marked, mix: mix)
        if item.kind != .folder { exportMenu(src) }
        OverviewMenuButton { store.ownTracksDeep(item.id) }
        AnalysisMenuButtons { store.ownTracksDeep(item.id) }
        ImportMenuButton(source: item.name) { store.ownTracksDeep(item.id) }
        CloudMenuButton(label: item.name) { store.ownTracksDeep(item.id) }
    }
}

/// „Verschieben nach“: PLAYLISTS oben oder ein eigener Ordner (nicht der Eintrag selbst oder darunter)
struct MoveMenu: View {
    @Environment(LibraryStore.self) private var store
    let item: PlaylistItem

    var body: some View {
        let tree = store.playlists
        let current = tree.parent(of: item.id) ?? nil
        Menu("Verschieben nach") {
            Button("PLAYLISTS (oben)") { move(nil) }.disabled(current == nil)
            ForEach(tree.folders.filter { $0.item.id != item.id && !tree.isDescendant($0.item.id, of: item.id) }, id: \.item.id) { f in
                Button(String(repeating: "   ", count: f.depth + 1) + OwnGlyph.folder + " " + f.item.name) { move(f.item.id) }
                    .disabled(current == f.item.id)
            }
        }
    }

    private func move(_ to: UUID?) { store.editPlaylists(String(localized: "Verschieben")) { $0.move(item.id, into: to) } }
}

/// Umbenennen, Löschen mit Rückfrage, Smartlist-Editor – am Baum
struct PlaylistTreeDialogs: ViewModifier {
    @Environment(LibraryStore.self) private var store
    @Bindable var ui: PlaylistTreeUI
    @Binding var selection: BrowserSource

    func body(content: Content) -> some View {
        content
            .alert("Umbenennen", isPresented: Binding(get: { ui.renaming != nil }, set: { if !$0 { ui.renaming = nil } })) {
                TextField("Name", text: $ui.renameText)
                Button("OK") {
                    if let it = ui.renaming {
                        store.editPlaylists(String(localized: "Umbenennen")) { $0.rename(it.id, to: ui.renameText) }
                    }
                    ui.renaming = nil
                }
                Button("Abbrechen", role: .cancel) { ui.renaming = nil }
            }
            .alert(deleteTitle, isPresented: Binding(get: { ui.deleting != nil }, set: { if !$0 { ui.deleting = nil } })) {
                Button("Löschen", role: .destructive) {
                    if let it = ui.deleting { store.editPlaylists(String(localized: "Löschen")) { $0.remove(it.id) } }
                    ui.deleting = nil
                }
                Button("Abbrechen", role: .cancel) { ui.deleting = nil }
            } message: {
                Text(deleteMessage)
            }
            .sheet(item: $ui.editing) { draft in
                SmartlistEditor(draft: draft) { saved in
                    selection = .own(OwnRef(saved))
                    ui.rootOpen = true
                    if let p = draft.parent { ui.collapsed.remove(p) }
                }
            }
    }

    private var deleteTitle: String {
        guard let it = ui.deleting else { return "" }
        return String(localized: "„\(it.name)“ löschen?")
    }

    private var deleteMessage: String {
        guard let it = ui.deleting else { return "" }
        switch it.kind {
        case .folder:
            let n = it.descendantCount
            return n == 0 ? String(localized: "Leerer Ordner. ⌘Z holt ihn zurück.")
                : String(localized: "Mit \(n) Einträgen darin. ⌘Z holt alles zurück.")
        case .playlist: return String(localized: "Playlist mit \(it.tracks.count) Tracks (die Tracks bleiben in der Collection). ⌘Z holt sie zurück.")
        case .smartlist: return String(localized: "Smartlist (nur die Regeln). ⌘Z holt sie zurück.")
        }
    }
}
