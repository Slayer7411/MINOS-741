import Foundation

/// Modus einer Kopplung: Session (alles, wie bisher), B2B (nur Takt), aus (gekoppelt, aber ohne Verbindung)
public enum PairMode: String, Codable, Sendable, CaseIterable {
    case session, b2b, off
}

/// Ein gekoppelter Mac: Kennung (Keychain-Konto, nur lokal), Name für die Anzeige, Modus
public struct PairedPeer: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var mode: PairMode

    public init(id: String, name: String, mode: PairMode) {
        self.id = id
        self.name = name
        self.mode = mode
    }
}

extension PairMode {
    /// Wirksam auf einer Verbindung: der strengere der beiden Modi (off > b2b > session)
    public static func effective(_ a: PairMode, _ b: PairMode) -> PairMode {
        if a == .off || b == .off { return .off }
        return a == .b2b || b == .b2b ? .b2b : .session
    }
}

/// Liste der gekoppelten Macs. Höchstens ein Session-Partner, höchstens 7 B2B-Partner (8 Macs insgesamt)
public enum PairPeers {
    public static let maxSession = 1
    public static let maxB2B = 7

    /// Grund, warum ein Mac nicht in den Modus aufgenommen wird
    public enum Refusal: Equatable, Sendable {
        case sessionTaken, groupFull
    }

    /// Prüfung für `mode`; `id` ist der betroffene Mac (zählt nicht gegen sich selbst)
    public static func refusal(for mode: PairMode, id: String, in list: [PairedPeer]) -> Refusal? {
        let others = list.filter { $0.id != id && $0.mode == mode }.count
        switch mode {
        case .session: return others >= maxSession ? .sessionTaken : nil
        case .b2b: return others >= maxB2B ? .groupFull : nil
        case .off: return nil
        }
    }

    /// Liste mit neuem Modus für `id`; nil = abgelehnt (Grenze erreicht). Unbekannte Kennung: nil
    public static func setting(_ mode: PairMode, id: String, in list: [PairedPeer]) -> [PairedPeer]? {
        guard list.contains(where: { $0.id == id }), refusal(for: mode, id: id, in: list) == nil else { return nil }
        return list.map { p in
            var q = p
            if q.id == id { q.mode = mode }
            return q
        }
    }

    /// Aufnahme eines neuen Macs; nil = abgelehnt. Eine vorhandene Kennung wird nur aktualisiert
    public static func adding(_ peer: PairedPeer, to list: [PairedPeer]) -> [PairedPeer]? {
        guard refusal(for: peer.mode, id: peer.id, in: list) == nil else { return nil }
        return list.filter { $0.id != peer.id } + [peer]
    }

    /// Alter Einzelpartner (`pair.peerID` / `pair.peerName`) wird Session-Partner, sobald es noch keine Liste gibt
    public static func migrated(list: [PairedPeer]?, legacyID: String?, legacyName: String?) -> [PairedPeer] {
        if let list { return list }
        guard let id = legacyID, let name = legacyName, !id.isEmpty else { return [] }
        return [PairedPeer(id: id, name: name, mode: .session)]
    }
}

/// Führung der B2B-Gruppe: wer Takt führt. Der spätere Anspruch (Lamport-Zähler) gewinnt, bei Gleichstand die kleinere
/// Kennung des Führenden
public struct PairLead: Equatable, Sendable {
    public var lamport: Int
    public var holder: String?

    public init(lamport: Int = 0, holder: String? = nil) {
        self.lamport = lamport
        self.holder = holder
    }

    /// Anspruch (`lamport`, `holder`) übernehmen, wenn er gewinnt
    public mutating func accept(lamport: Int, holder: String) -> Bool {
        guard Self.wins(lamport: lamport, holder: holder, over: self) else { return false }
        self = PairLead(lamport: lamport, holder: holder)
        return true
    }

    /// Eigener Anspruch: nächster Zähler, dieser Mac führt
    public mutating func claim(by id: String) -> PairLead {
        self = PairLead(lamport: lamport + 1, holder: id)
        return self
    }

    public static func wins(lamport: Int, holder: String, over cur: PairLead) -> Bool {
        if lamport != cur.lamport { return lamport > cur.lamport }
        guard let h = cur.holder else { return true }
        return holder < h
    }

    /// Rolle dieses Macs: `group` = führt über die Gruppe (auch ohne bekannten Führenden), `pair` = Takt entscheidet
    /// das Paar (Session-Partner, PairTempo), `follow` = folgt dem Führenden
    public enum Role: Equatable, Sendable { case group, pair, follow }

    public static func role(own: String, holder: String?, partner: String?, connected: Set<String>) -> Role {
        guard let h = holder else { return .group }
        if h == own { return partner.map(connected.contains) == true ? .pair : .group }
        if h == partner { return connected.contains(h) ? .pair : .group }
        return connected.contains(h) ? .follow : .group
    }
}

/// Was über eine Verbindung geht: Session alles, B2B nur Takt (Tempo, Clock, Führung, Hello ohne Gespielt-Stand)
public enum PairFilter {
    public static func allows(_ m: PairMessage, mode: PairMode) -> Bool {
        switch mode {
        case .off: return false
        case .session: return true
        case .b2b:
            switch m {
            case .hello, .clock, .tempo, .lead, .mode: return true
            default: return false
            }
        }
    }

    /// Nachricht für diese Verbindung (nil = nicht zulässig); im B2B-Modus geht das Hello ohne Gespielt-Stand
    public static func filtered(_ m: PairMessage, mode: PairMode) -> PairMessage? {
        guard allows(m, mode: mode) else { return nil }
        if mode == .b2b, case let .hello(writes, decks, version, name, _) = m {
            return .hello(writes: writes, decks: decks, version: version, name: name, played: [])
        }
        return m
    }
}
