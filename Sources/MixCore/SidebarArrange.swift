import Foundation

/// Farbmarke eines Eintrags der Seitenleiste (fehlt = keine). Nur in den Einstellungen, nie in der Collection-Datei
public enum SidebarMark: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, blue, purple, grey
}

/// Reihenfolge und Farbmarken der Seitenleiste als Überlagerung über den Einträgen. Schlüssel sind stabile Kennungen
/// (Ordnerpfad, Collection-UUID, eigene Playlist-ID); Ordner und Collection-Datei bleiben unberührt.
public struct SidebarArrange: Equatable, Sendable {
    /// Reihenfolge je Ebene (Gruppe), vollständige Liste der Schlüssel in Anzeigeordnung
    public var order: [String: [String]]
    /// Farbmarke je Schlüssel
    public var marks: [String: SidebarMark]

    public init(order: [String: [String]] = [:], marks: [String: SidebarMark] = [:]) {
        self.order = order
        self.marks = marks
    }

    /// Schlüssel einer Ebene in Anzeigeordnung: gespeicherte zuerst (in ihrer Reihenfolge), unbekannte Schlüssel danach
    /// in ihrer natürlichen Reihenfolge; nicht mehr vorhandene Schlüssel werden ignoriert
    public func sorted(_ group: String, _ ids: [String]) -> [String] {
        guard let saved = order[group], !saved.isEmpty else { return ids }
        let present = Set(ids)
        var rank: [String: Int] = [:]
        for (i, k) in saved.enumerated() where present.contains(k) && rank[k] == nil { rank[k] = i }
        let known = ids.filter { rank[$0] != nil }.sorted { rank[$0]! < rank[$1]! }
        return known + ids.filter { rank[$0] == nil }
    }

    /// `id` vor `target` in die Ebene `group` setzen (`target` nil oder unbekannt: ans Ende). `ids` sind die aktuellen
    /// Schlüssel der Ebene in natürlicher Reihenfolge; die Ebene wird danach vollständig gespeichert
    public mutating func move(_ id: String, before target: String?, in group: String, ids: [String]) {
        guard id != target, ids.contains(id) else { return }
        var list = sorted(group, ids).filter { $0 != id }
        if let target, let i = list.firstIndex(of: target) { list.insert(id, at: i) } else { list.append(id) }
        order[group] = list
    }

    public func mark(_ id: String) -> SidebarMark? { marks[id] }

    public mutating func setMark(_ mark: SidebarMark?, for id: String) {
        if let mark { marks[id] = mark } else { marks[id] = nil }
    }
}

extension SidebarArrange: Codable {
    private enum CodingKeys: String, CodingKey { case order, marks }

    /// Fehlende Schlüssel (alte Einstellungen) bekommen ihren Standard; unbekannte Farben fallen weg
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = (try? c.decodeIfPresent([String: [String]].self, forKey: .order)) ?? [:]
        let raw = (try? c.decodeIfPresent([String: String].self, forKey: .marks)) ?? [:]
        marks = raw.compactMapValues { SidebarMark(rawValue: $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order, forKey: .order)
        try c.encode(marks.mapValues(\.rawValue), forKey: .marks)
    }
}
