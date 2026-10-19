import SwiftUI
import AppKit
import MixCore

extension SidebarMark {
    /// Name im Menü „Farbe“
    var title: String {
        switch self {
        case .red: String(localized: "Rot")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Gelb")
        case .green: String(localized: "Grün")
        case .blue: String(localized: "Blau")
        case .purple: String(localized: "Lila")
        case .grey: String(localized: "Grau")
        }
    }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .grey: .gray
        }
    }
}

/// Schlüssel der Überlagerung: Ordner (Pfad), Collection (UUID, bei Ordnern der Pfad aus Namen), eigener Eintrag (UUID)
enum SidebarKey {
    static func folder(_ path: String) -> String { "mf:" + path }
    static func folderPath(_ key: String) -> String { String(key.dropFirst(3)) }
    /// Ebene der Ordner: Wurzeln (parent nil) bzw. Unterordner von `parent`
    static func folderGroup(_ parent: String?) -> String { "m:" + (parent ?? "") }

    static func collection(_ n: PlaylistNode, parent: String) -> String {
        n.uuid.isEmpty ? "cf:" + parent + "/" + n.name : "cu:" + n.uuid
    }
    static func collectionGroup(_ parent: String) -> String { "c:" + parent }

    static func own(_ id: UUID) -> String { "o:" + id.uuidString }
}

/// Umordnen in der Seitenleiste: der Zug trägt Ebene und Schlüssel. Er ist getrennt von Track-Zügen (`TrackDrag`) und
/// Baum-Zügen (`TreeDrag`), damit Tracks weiter auf Collection-Playlists fallen und Umordnen nur in der eigenen Ebene geht
enum SidebarDrag {
    static let prefix = "minos741-sidebar:"

    @MainActor
    static func provider(group: String, key: String, favorite: BrowserFavorite?) -> NSItemProvider {
        _ = FavoriteDrag.provider(favorite)   // Favoritenleiste liest den Favoriten von dort (wie beim Baum)
        TreeDragGate.beginTree()              // Ablage-Schicht des Baums übernimmt, sobald mit gedrückter Taste gezogen wird
        return NSItemProvider(object: (prefix + group + "\n" + key) as NSString)
    }

    /// Ebene und Schlüssel eines Umordnen-Zugs; nil für fremde Texte
    static func item(_ s: String) -> (group: String, key: String)? {
        guard s.hasPrefix(prefix) else { return nil }
        let parts = s.dropFirst(prefix.count).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}

extension View {
    /// Eintrag der Seitenleiste ziehbar zum Umordnen in seiner Ebene (`group`) und auf einen Favoriten-Platz
    func sidebarDrag(group: String, key: String, favorite: @escaping @MainActor () -> BrowserFavorite?) -> some View {
        itemProvider {
            let make = { MainActor.assumeIsolated { SidebarProviderBox(provider: SidebarDrag.provider(group: group, key: key, favorite: favorite())) } }
            return (Thread.isMainThread ? make() : DispatchQueue.main.sync(execute: make)).provider
        }
    }

    /// Kopf eines Abschnitts oben (Collection, MUSIC FOLDERS, EXPLORER): ziehbar und Ziel zum Umordnen der Abschnitte
    /// (Ebene „root“). PLAYLISTS hat eigene Ablage (Baum-Züge) und setzt die Umordnung selbst dazu
    func sectionHeader(_ ui: PlaylistTreeUI, _ s: SidebarSection, favorite: @escaping @MainActor () -> BrowserFavorite? = { nil }) -> some View {
        sectionDrag(ui, s, favorite: favorite)
            .treeDropZone(ui.regions, name: "section \(s.rawValue)", highlight: { on in
                ui.sidebarTarget = on ? s.rawValue : (ui.sidebarTarget == s.rawValue ? nil : ui.sidebarTarget)
            }, accepts: { SidebarSection.carries($0) }) { strings in
                ui.reorderSection(strings, to: s)
            }
    }

    /// Kopf eines Abschnitts ziehbar (zum Umordnen der Abschnitte) und markiert, solange ein Zug darauf zeigt
    func sectionDrag(_ ui: PlaylistTreeUI, _ s: SidebarSection, favorite: @escaping @MainActor () -> BrowserFavorite? = { nil }) -> some View {
        sidebarDrag(group: SidebarArrange.sectionGroup, key: s.rawValue, favorite: favorite)
            .background(ui.sidebarTarget == s.rawValue ? Theme.chitinRaised : .clear)
    }

    /// Farbmarke als schmaler Balken am linken Rand der Zeile
    func sidebarMark(_ ui: PlaylistTreeUI, _ key: String) -> some View {
        overlay(alignment: .leading) {
            if let m = ui.arrange.mark(key) { Rectangle().fill(m.color).frame(width: 3) }
        }
    }
}

extension SidebarSection {
    /// Zug trägt einen Abschnitt (Umordnen der Abschnitte oben)
    static func carries(_ strings: [String]) -> Bool {
        strings.contains { SidebarDrag.item($0)?.group == SidebarArrange.sectionGroup }
    }
}

extension PlaylistTreeUI {
    /// Ordner (Pfade) einer Ebene in Anzeigeordnung
    func folders(_ paths: [String], group: String) -> [String] {
        arrange.sorted(group, paths.map(SidebarKey.folder)).map(SidebarKey.folderPath)
    }

    /// Abschnitte oben in Anzeigeordnung
    var sections: [SidebarSection] { arrange.sectionOrder() }

    /// Abschnitt auf `target` ziehen, Richtung wie bei `SidebarArrange.move` (nur Abschnitte; sonst false)
    func reorderSection(_ strings: [String], to target: SidebarSection) -> Bool {
        reorder(strings, to: target.rawValue, group: SidebarArrange.sectionGroup, ids: SidebarSection.allCases.map(\.rawValue))
    }

    func resetSectionOrder() {
        var a = arrange
        a.resetSectionOrder()
        commit(a)
    }
}

/// Menüpunkt „Reihenfolge zurücksetzen“ an einem Abschnitt oben
struct SectionResetButton: View {
    let ui: PlaylistTreeUI

    var body: some View {
        Button("Reihenfolge zurücksetzen") { ui.resetSectionOrder() }
    }
}

private struct SidebarProviderBox: @unchecked Sendable { let provider: NSItemProvider }

/// Menü „Farbe“ an einem Eintrag der Seitenleiste
struct SidebarMarkMenu: View {
    let ui: PlaylistTreeUI
    let key: String

    var body: some View {
        Menu("Farbe") {
            Button("Keine") { ui.setMark(nil, key) }
            ForEach(SidebarMark.allCases, id: \.self) { m in
                Button(m.title) { ui.setMark(m, key) }
            }
        }
    }
}
