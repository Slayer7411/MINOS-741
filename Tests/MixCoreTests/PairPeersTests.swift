import Foundation
import Testing
@testable import MixCore

@Test func pairMigrationMovesSinglePeerToSession() {
    let list = PairPeers.migrated(list: nil, legacyID: "id-1", legacyName: "Studio")
    #expect(list == [PairedPeer(id: "id-1", name: "Studio", mode: .session)])
    // vorhandene Liste gewinnt über den alten Eintrag
    let kept = PairPeers.migrated(list: [PairedPeer(id: "x", name: "X", mode: .b2b)], legacyID: "id-1", legacyName: "Studio")
    #expect(kept == [PairedPeer(id: "x", name: "X", mode: .b2b)])
    #expect(PairPeers.migrated(list: nil, legacyID: nil, legacyName: nil).isEmpty)
}

@Test func pairSecondSessionPeerIsRefused() {
    let one = [PairedPeer(id: "a", name: "A", mode: .session)]
    #expect(PairPeers.refusal(for: .session, id: "b", in: one) == .sessionTaken)
    #expect(PairPeers.adding(PairedPeer(id: "b", name: "B", mode: .session), to: one) == nil)
    // derselbe Mac darf seinen Modus behalten
    #expect(PairPeers.refusal(for: .session, id: "a", in: one) == nil)
    #expect(PairPeers.setting(.session, id: "a", in: one) == one)
    // ein B2B-Mac wird nicht Session, solange der Session-Platz belegt ist
    let mixed = one + [PairedPeer(id: "c", name: "C", mode: .b2b)]
    #expect(PairPeers.setting(.session, id: "c", in: mixed) == nil)
}

@Test func pairEighthB2BPeerIsRefused() {
    let seven = (1...7).map { PairedPeer(id: "p\($0)", name: "P\($0)", mode: .b2b) }
    #expect(PairPeers.refusal(for: .b2b, id: "p8", in: seven) == .groupFull)
    #expect(PairPeers.adding(PairedPeer(id: "p8", name: "P8", mode: .b2b), to: seven) == nil)
    // sieben B2B plus ein Session-Partner: acht Macs, der Session-Partner zählt nicht gegen die B2B-Grenze
    let withSession = seven.dropLast() + [PairedPeer(id: "s", name: "S", mode: .session)]
    #expect(PairPeers.refusal(for: .b2b, id: "p7", in: Array(withSession)) == nil)
    #expect(PairPeers.adding(PairedPeer(id: "p8", name: "P8", mode: .b2b), to: Array(withSession)) != nil)
}

@Test func pairModeChangeKeepsOtherPeers() {
    let list = [PairedPeer(id: "a", name: "A", mode: .session), PairedPeer(id: "b", name: "B", mode: .b2b)]
    let off = PairPeers.setting(.off, id: "a", in: list)
    #expect(off?.first?.mode == .off)
    #expect(off?.last == PairedPeer(id: "b", name: "B", mode: .b2b))
    #expect(PairPeers.setting(.b2b, id: "missing", in: list) == nil)
}

@Test func pairB2BFilterDropsLibraryPlayedSettingsAndDebug() {
    #expect(PairFilter.allows(.tempo(bpm: 124), mode: .b2b))
    #expect(PairFilter.allows(.clock(playingMaster: true, leader: true), mode: .b2b))
    #expect(PairFilter.allows(.lead(lamport: 2, holder: "a"), mode: .b2b))
    #expect(PairFilter.allows(.hello(writes: true, decks: [0], version: 6, name: "A", played: []), mode: .b2b))
    #expect(!PairFilter.allows(.playedSet(["x"]), mode: .b2b))
    #expect(!PairFilter.allows(.played(add: ["x"], remove: []), mode: .b2b))
    #expect(!PairFilter.allows(.state(writes: true, decks: [0]), mode: .b2b))
    #expect(!PairFilter.allows(.live(true), mode: .b2b))
    #expect(!PairFilter.allows(.debugRequest(id: 1, command: "ping", args: ""), mode: .b2b))
    #expect(!PairFilter.allows(.debugReply(id: 1, ok: true, body: "{}"), mode: .b2b))
    // Session: alles; aus: nichts
    #expect(PairFilter.allows(.played(add: ["x"], remove: []), mode: .session))
    #expect(PairFilter.allows(.debugRequest(id: 1, command: "ping", args: ""), mode: .session))
    #expect(!PairFilter.allows(.tempo(bpm: 120), mode: .off))
}

@Test func pairB2BHelloCarriesNoPlayedState() {
    let hello = PairMessage.hello(writes: true, decks: [0, 2], version: 6, name: "A", played: ["x", "y"])
    #expect(PairFilter.filtered(hello, mode: .b2b) == .hello(writes: true, decks: [0, 2], version: 6, name: "A", played: []))
    #expect(PairFilter.filtered(hello, mode: .session) == hello)
    #expect(PairFilter.filtered(.playedSet(["x"]), mode: .b2b) == nil)
}

@Test func pairLeadLaterClaimWins() {
    var lead = PairLead()
    let first = lead.accept(lamport: 1, holder: "m")
    let tie = lead.accept(lamport: 1, holder: "z")        // Gleichstand: größere Kennung verliert
    let tieWin = lead.accept(lamport: 1, holder: "a")     // Gleichstand: kleinere Kennung gewinnt
    #expect(first && !tie && tieWin)
    #expect(lead.holder == "a")
    let older = lead.accept(lamport: 0, holder: "0")      // älterer Anspruch
    let later = lead.accept(lamport: 2, holder: "z")      // späterer Anspruch gewinnt immer
    #expect(!older && later)
    #expect(lead.holder == "z")
}

@Test func pairLeadTakeLeadIncrementsCounter() {
    var lead = PairLead(lamport: 4, holder: "a")
    let claimed = lead.claim(by: "b")
    #expect(claimed == PairLead(lamport: 5, holder: "b"))
    #expect(lead == claimed)
}

@Test func pairLeadRoles() {
    // ohne bekannten Führenden führt jeder Mac wie bisher
    #expect(PairLead.role(own: "a", holder: nil, partner: nil, connected: []) == .group)
    // Führender ist dieser Mac, ohne Session-Partner: er führt
    #expect(PairLead.role(own: "a", holder: "a", partner: nil, connected: ["c"]) == .group)
    // Führender ist das eigene Paar (Session-Partner verbunden): PairTempo entscheidet
    #expect(PairLead.role(own: "a", holder: "b", partner: "b", connected: ["b", "c"]) == .pair)
    #expect(PairLead.role(own: "a", holder: "a", partner: "b", connected: ["b", "c"]) == .pair)
    // anderer B2B-Mac führt: dieser folgt
    #expect(PairLead.role(own: "a", holder: "c", partner: "b", connected: ["b", "c"]) == .follow)
    // Führender über einen Dritten erreichbar: dieser folgt (kein direkter Draht nötig)
    #expect(PairLead.role(own: "a", holder: "d", partner: "b", connected: ["b", "c"]) == .follow)
    // Session-Partner (Führender) weg: Fallback wie ohne Führung
    #expect(PairLead.role(own: "a", holder: "b", partner: "b", connected: ["c"]) == .group)
}

@Test func pairLeadHandoverMovesRoles() {
    // C übernimmt: bei A folgt man C, bei C führt C
    var atA = PairLead(lamport: 1, holder: "a")
    let moved = atA.accept(lamport: 2, holder: "c")
    #expect(moved)
    #expect(PairLead.role(own: "a", holder: atA.holder, partner: "b", connected: ["b", "c"]) == .follow)
    #expect(PairLead.role(own: "c", holder: atA.holder, partner: nil, connected: ["a"]) == .group)
}

@Test func pairEffectiveModeIsTheStricterOne() {
    #expect(PairMode.effective(.session, .session) == .session)
    #expect(PairMode.effective(.session, .b2b) == .b2b)
    #expect(PairMode.effective(.b2b, .session) == .b2b)
    #expect(PairMode.effective(.session, .off) == .off)
    #expect(PairFilter.allows(.mode(.session), mode: .b2b))
}

@Test func pairTakeoverWaitsForGrace() {
    // kurzer WLAN-Aussetzer (unter der Frist) löst keinen Wechsel aus
    #expect(!PairTakeover.due(silentMicros: 2_000_000))
    #expect(!PairTakeover.due(silentMicros: PairTakeover.graceMicros))
    #expect(PairTakeover.due(silentMicros: 3_500_000))
}

@Test func pairTakeoverAllMembersAgreeOnSuccessor() {
    // Gruppe a, b, c, d; a führt und fällt aus. Jeder verbleibende Mac rechnet auf seinen verbundenen Macs (ohne a)
    let group: Set<String> = ["a", "b", "c", "d"]
    var leads: [PairLead] = []
    for me in group.subtracting(["a"]) {
        let connected = group.subtracting([me, "a"])
        var lead = PairLead(lamport: 1, holder: "a")
        if let next = PairTakeover.successor(members: connected.union([me]), old: "a") { lead.takeover(to: next) }
        leads.append(lead)
    }
    #expect(leads.count == 3)
    #expect(leads.allSatisfy { $0 == PairLead(lamport: 2, holder: "b") })
}

@Test func pairTakeoverSuccessorWithoutCandidates() {
    #expect(PairTakeover.successor(members: [], old: "a") == nil)
    #expect(PairTakeover.successor(members: ["a"], old: "a") == nil)
    // Führender fällt erneut aus: nächster Kandidat, der alte bleibt außen vor
    #expect(PairTakeover.successor(members: ["b", "c", "d"], old: "b") == "c")
}

@Test func pairTakeoverReturningLeaderBecomesFollower() {
    // a kehrt zurück, b führt seit Lamport 2: a nimmt den Anspruch an und folgt
    var atA = PairLead(lamport: 1, holder: "a")
    let returned = atA.accept(lamport: 2, holder: "b")
    #expect(returned)
    #expect(atA.holder == "b")
    #expect(PairLead.role(own: "a", holder: atA.holder, partner: nil, connected: ["b", "c"]) == .follow)
    // a schiebt sich nicht zurück: der alte Anspruch (Lamport 1) gewinnt nicht mehr
    let back = atA.accept(lamport: 1, holder: "a")
    #expect(!back)
    #expect(atA.holder == "b")
}

@Test func pairTakeoverManualTaktAfterwardsWins() {
    var atC = PairLead(lamport: 1, holder: "a")
    atC.takeover(to: "b")
    // TAKT bei c: nächster Zähler, c führt und setzt sich gegen die Übernahme durch
    let claimed = atC.claim(by: "c")
    #expect(claimed == PairLead(lamport: 3, holder: "c"))
    var atB = PairLead(lamport: 2, holder: "b")
    let won = atB.accept(lamport: 3, holder: "c")
    #expect(won)
    #expect(atB.holder == "c")
}
