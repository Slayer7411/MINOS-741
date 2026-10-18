import Foundation

/// Reihenfolge der Playlists der Collection beim Ablegen und Umsortieren (reine Funktionen, ohne Datei)
public enum CollectionPlaylists {
    /// `keys` vor Position `index` in `list` einfügen (≥ count = ans Ende). Schon vorhandene Schlüssel kommen nicht
    /// doppelt dazu, außer `allowDuplicates`
    public static func inserting(_ keys: [String], into list: [String], at index: Int, allowDuplicates: Bool = false) -> [String] {
        var have = Set(list)
        let new = keys.filter { allowDuplicates || have.insert($0).inserted }
        let at = max(0, min(list.count, index))
        return Array(list[..<at]) + new + Array(list[at...])
    }

    /// `keys` (in ihrer Reihenfolge in der Liste) vor den Platz `index` verschieben (Index vor dem Verschieben,
    /// `list.count` = ans Ende). Liste ohne die Schlüssel bleibt in ihrer Reihenfolge
    public static func moving(_ keys: [String], in list: [String], to index: Int) -> [String] {
        let set = Set(keys)
        let moving = list.filter { set.contains($0) }
        guard !moving.isEmpty else { return list }
        let target = max(0, min(list.count, index))
        let before = list[..<target].filter { set.contains($0) }.count
        var rest = list.filter { !set.contains($0) }
        rest.insert(contentsOf: moving, at: max(0, min(rest.count, target - before)))
        return rest
    }
}
