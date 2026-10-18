import AppKit
import MixCore

/// Track-Tabelle: Tracks ziehen, in eigene Playlists ablegen / dort umsortieren, ⌫ entfernt, Menü „Zur Playlist“
extension TrackTableController {
    /// Eine Zeile = ein Eintrag: Text für Decks, Baum und Tabelle (mehrere Zeilen = mehrere Einträge), dazu die Datei für
    /// den Finder (nur wenn sie auf der Platte liegt). Ohne Dateityp zieht AppKit nur Text, Finder nimmt nichts
    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let r = shownRows
        guard row >= 0, row < r.count else { return nil }
        let t = r[row]
        let item = NSPasteboardItem()
        item.setString(TrackDrag.prefix + t.key, forType: .string)
        if t.fileExists, !t.path.isEmpty { item.setString(URL(fileURLWithPath: t.path).absoluteString, forType: .fileURL) }
        return item
    }

    /// Ziehen aus der Tabelle beginnt und endet: die Ablage-Schicht des Baums nimmt den Zeiger nur dazwischen an
    func tableView(_ tv: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        TreeDragGate.begin()
    }

    func tableView(_ tv: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        TreeDragGate.end()
    }

    func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard model?.ownPlaylistID != nil || model?.collectionPlaylistID != nil, !dropKeys(info.draggingPasteboard).isEmpty else { return [] }
        tv.setDropRow(row, dropOperation: .above)
        return (info.draggingSource as? NSTableView) === tv ? .move : .copy
    }

    func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let model, let store else { return false }
        let keys = dropKeys(info.draggingPasteboard)
        guard !keys.isEmpty else { return false }
        let reorder = (info.draggingSource as? NSTableView) === tv
        if let id = model.ownPlaylistID {
            drop(keys, at: row, into: id, reorder: reorder, store: store, model: model)
            return true
        }
        if let id = model.collectionPlaylistID {
            dropCollection(keys, at: row, into: id, reorder: reorder, store: store, model: model)
            return true
        }
        return false
    }

    /// Ablegen auf eine Playlist der Collection: Reihenfolge und Einfügen gehen in die Datei (Sicherung, Prüfung)
    func dropCollection(_ keys: [String], at row: Int, into id: UUID, reorder: Bool, store: LibraryStore, model: BrowserPaneModel) {
        guard let node = store.collectionPlaylist(id) else { return }
        let rows = shownRows
        let index = row >= 0 && row < rows.count ? node.trackKeys.firstIndex(of: rows[row].key) ?? node.trackKeys.count : node.trackKeys.count
        if reorder {
            store.moveInCollectionPlaylist(id, keys: keys, to: index)
            if !model.sortOrder.isEmpty { model.sortOrder = [] }
        } else {
            store.addToCollectionPlaylist(id, keys: keys, at: index)
        }
    }

    /// Ablegen vor Zeile `row` der angezeigten Liste: gleiche Tabelle = Reihenfolge (zeigt danach die Playlist-
    /// Reihenfolge), sonst einfügen
    func drop(_ keys: [String], at row: Int, into id: UUID, reorder: Bool, store: LibraryStore, model: BrowserPaneModel) {
        guard let item = store.playlists.item(id) else { return }
        let rows = shownRows
        let index = row >= 0 && row < rows.count ? item.tracks.firstIndex(of: rows[row].key) ?? item.tracks.count : item.tracks.count
        if reorder {
            store.editPlaylists(String(localized: "Reihenfolge ändern")) { $0.moveTracks(keys, in: id, to: index) }
            if !model.sortOrder.isEmpty { model.sortOrder = [] }
        } else {
            store.addToPlaylist(keys, id, at: index)
        }
    }

    static func dragKeys(_ pb: NSPasteboard) -> [String] {
        (pb.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }.compactMap(TreeDrag.track)
    }

    /// Dateien aus dem Finder (Pfade)
    static func filePaths(_ pb: NSPasteboard) -> [String] {
        (pb.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL).flatMap { URL(string: $0)?.path } }
    }

    /// Tracks zum Ablegen: eigene Einträge, dazu Finder-Dateien, die in der Collection stehen (andere werden ignoriert)
    func dropKeys(_ pb: NSPasteboard) -> [String] {
        let text = Self.dragKeys(pb)
        let files = Set(Self.filePaths(pb))
        guard !files.isEmpty, let store else { return text }
        return text + store.tracks.filter { files.contains($0.path) }.map(\.key)
    }

    /// ⌫: Auswahl aus der eigenen Playlist bzw. der Preparation
    func deleteKey() -> Bool {
        guard let model, let store, !model.selection.isEmpty else { return false }
        let ids = model.selection
        if let id = model.ownPlaylistID {
            store.removeFromPlaylist(ids, id)
            return true
        }
        if case .preparation = model.source {
            store.editPreparation(String(localized: "Aus Preparation entfernen")) { $0.removeAll { ids.contains($0) } }
            return true
        }
        return false
    }
}

extension BrowserPaneModel {
    /// eigene Playlist als Quelle (Ablegen, Reihenfolge, ⌫)
    var ownPlaylistID: UUID? {
        if case let .own(r) = source, r.kind == .playlist { return r.id }
        return nil
    }
}

extension BrowserPaneModel {
    /// Playlist der Collection als Quelle (Ablegen, Reihenfolge in die Datei)
    var collectionPlaylistID: UUID? {
        if case let .node(n) = source, n.kind == .playlist { return n.id }
        return nil
    }
}
