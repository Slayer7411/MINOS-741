import Foundation

/// Zwei-Mac-Modus (bleibt auf dem Mac, wirkt sofort): welcher Mac schreibt, welche Decks dieser Mac bedient
struct PairSetup: Codable, Equatable {
    var on = false
    /// dieser Mac schreibt in Collection und History-Ordner (genau einer der beiden)
    var writes = true
    /// Decks dieses Macs (0 = A … 3 = D), höchstens 2, aufsteigend
    var decks = [0, 2]
    /// Fernzugriff zum Analysieren: der andere Mac darf Stand abfragen und Einstellungen ändern (scripts/pairdebug.sh)
    var remoteDebug = false

    static let maxDecks = 2

    init() {}

    /// fehlende Felder -> Standard
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? nil ?? on
        writes = (try? c.decodeIfPresent(Bool.self, forKey: .writes)) ?? nil ?? writes
        decks = Self.valid((try? c.decodeIfPresent([Int].self, forKey: .decks)) ?? nil ?? decks)
        remoteDebug = (try? c.decodeIfPresent(Bool.self, forKey: .remoteDebug)) ?? nil ?? remoteDebug
    }

    static func valid(_ d: [Int]) -> [Int] {
        let v = Array(Set(d.filter { (0..<4).contains($0) })).sorted().prefix(maxDecks)
        return v.isEmpty ? [0] : Array(v)
    }

    /// Deck an/aus: das letzte bleibt, ein drittes verdrängt das zuerst gewählte
    static func toggled(_ decks: [Int], _ d: Int) -> [Int] {
        if decks.contains(d) { return decks.count > 1 ? decks.filter { $0 != d } : decks }
        var n = decks + [d]
        if n.count > maxDecks { n.removeFirst(n.count - maxDecks) }
        return n.sorted()
    }
}

/// Anordnung der Decks: Platz links oben, links unten, rechts oben, rechts unten -> Deck (0 = A … 3 = D)
enum DeckLayout {
    static let slotNames = ["Links oben", "Links unten", "Rechts oben", "Rechts unten"]
    /// bisherige Anordnung: A links oben, C links unten, B rechts oben, D rechts unten
    static let defaultSlots = [0, 2, 1, 3]

    /// sichtbare Decks: Zwei-Mac-Modus seine Decks, sonst 1 (A), 2 (A, B) oder 4
    static func visible(deckCount: Int, pair: PairSetup) -> [Int] {
        if pair.on { return PairSetup.valid(pair.decks) }
        return deckCount <= 1 ? [0] : deckCount == 2 ? [0, 1] : [0, 1, 2, 3]
    }

    /// Spalten von oben nach unten; nur eine Spalte belegt -> links (volle Breite). Genau zwei Decks: in der Reihenfolge
    /// ihrer Plätze nebeneinander oder übereinander
    static func columns(visible: [Int], slots: [Int], twoSideBySide: Bool = true) -> (left: [Int], right: [Int]) {
        let s = normalized(slots)
        if visible.count == 2 {
            let two = s.filter(visible.contains)
            return twoSideBySide ? ([two[0]], [two[1]]) : (two, [])
        }
        let left = s[0...1].filter(visible.contains), right = s[2...3].filter(visible.contains)
        return left.isEmpty ? (right, []) : (left, right)
    }

    static func normalized(_ slots: [Int]) -> [Int] { Set(slots) == [0, 1, 2, 3] && slots.count == 4 ? slots : defaultSlots }

    /// Platz `slot` bekommt `deck`; der Platz, auf dem das Deck stand, bekommt das bisherige
    static func setting(_ slots: [Int], slot: Int, deck: Int) -> [Int] {
        var s = normalized(slots)
        guard (0..<4).contains(slot), let from = s.firstIndex(of: deck) else { return s }
        s.swapAt(slot, from)
        return s
    }
}
