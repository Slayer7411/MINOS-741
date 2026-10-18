import CryptoKit
import Foundation
import Testing
@testable import MixCore

/// Kopplung zweier Macs: Festlegung (Commit) beider Seiten, dann Aufdeckung; liefert die Ergebnisse beider Seiten
private func rendezvous(_ a: PairRendezvous, _ b: PairRendezvous) throws -> (a: PairSAS, b: PairSAS) {
    (try a.finish(peerCommit: b.commitment, reveal: b.reveal), try b.finish(peerCommit: a.commitment, reveal: a.reveal))
}

private func bytes(_ s: PairSAS) -> Data { PairCrypto.bytes(s.key) }

@Test func pairingBothSidesDeriveSameKeyAndCode() throws {
    let a = PairRendezvous(id: "id-alpha", name: "Alpha")
    let b = PairRendezvous(id: "id-beta", name: "Beta")
    let (sa, sb) = try rendezvous(a, b)
    #expect(sa.code == sb.code)
    #expect(sa.code.count == 6 && sa.code.allSatisfy(\.isNumber))
    #expect(bytes(sa) == bytes(sb))
    #expect(bytes(sa).count == 32)
    // Bestätigung: jede Seite prüft die des anderen mit dessen Id
    #expect(sa.verify(sb.confirmation(from: "id-beta"), from: "id-beta"))
    #expect(sb.verify(sa.confirmation(from: "id-alpha"), from: "id-alpha"))
    #expect(!sa.verify(sb.confirmation(from: "id-beta"), from: "id-alpha"))
}

@Test func pairingMismatchedRevealIsRejected() throws {
    let a = PairRendezvous(id: "id-alpha", name: "Alpha")
    let b = PairRendezvous(id: "id-beta", name: "Beta")
    let mallory = PairRendezvous(id: "id-beta", name: "Beta")   // anderer Schlüssel, gleiche Id
    // Der Partner hat sich auf b.commitment festgelegt, deckt aber mallory auf
    #expect(throws: PairAuthError.commitmentMismatch) { try a.finish(peerCommit: b.commitment, reveal: mallory.reveal) }
    // Eine Aufdeckung mit geändertem Namen passt ebenfalls nicht zur Festlegung
    let renamed = PairFrame.pairReveal(id: "id-beta", name: "Gamma", pub: b.publicKey, nonce: Data(repeating: 1, count: 32))
    #expect(throws: PairAuthError.commitmentMismatch) { try a.finish(peerCommit: b.commitment, reveal: renamed) }
    // eigene Id als Partner: abgelehnt
    #expect(throws: PairAuthError.rejected) { try a.finish(peerCommit: a.commitment, reveal: a.reveal) }
}

@Test func pairingDifferentEphemeralKeysGiveDifferentCodes() throws {
    let a = PairRendezvous(id: "id-alpha", name: "Alpha")
    let b = PairRendezvous(id: "id-beta", name: "Beta")
    let c = PairRendezvous(id: "id-beta", name: "Beta")
    let (ab, _) = try rendezvous(a, b)
    let (ac, _) = try rendezvous(a, c)
    #expect(ab.code != ac.code || bytes(ab) != bytes(ac))
    #expect(bytes(ab) != bytes(ac))
    // gleiche Schlüssel, andere Nonce: anderer Transkript-Hash, andere Zahl und anderer Schlüssel
    let a2 = PairRendezvous(id: "id-alpha", name: "Alpha")
    let (ab2, _) = try rendezvous(a2, b)
    #expect(bytes(ab2) != bytes(ab))
}

@Test func pairingCodeIsSixDigitsOverManyRuns() throws {
    var seen = Set<String>()
    for _ in 0..<40 {
        let (sa, _) = try rendezvous(PairRendezvous(id: "id-alpha", name: "Alpha"), PairRendezvous(id: "id-beta", name: "Beta"))
        #expect(sa.code.count == 6)
        seen.insert(sa.code)
    }
    #expect(seen.count > 1)
}

@Test func handshakeWithStoredKeyAuthenticatesBothWays() throws {
    let key = try rendezvous(PairRendezvous(id: "id-alpha", name: "Alpha"), PairRendezvous(id: "id-beta", name: "Beta")).a.key
    var a = PairHandshake(ownID: "id-alpha", ownName: "Alpha"), b = PairHandshake(ownID: "id-beta", ownName: "Beta")
    let pa = try b.receive(a.hello, key: { $0 == "id-alpha" ? key : nil })
    let pb = try a.receive(b.hello, key: { $0 == "id-beta" ? key : nil })
    #expect(try a.receive(pa!, key: { _ in key }) == nil)
    #expect(try b.receive(pb!, key: { _ in key }) == nil)
    #expect(a.session != nil && a.session == b.session)
    #expect(a.peerID == "id-beta" && b.peerID == "id-alpha")
}

@Test func handshakeRefusesUnpairedPeer() throws {
    var a = PairHandshake(ownID: "id-alpha", ownName: "Alpha")
    let c = PairHandshake(ownID: "id-gamma", ownName: "Gamma")
    #expect(throws: PairAuthError.unpaired) { try a.receive(c.hello, key: { _ in nil }) }
    #expect(a.channel() == nil)
}

@Test func pairFrameRoundTripsForPairingSteps() throws {
    let r = PairRendezvous(id: "id-alpha", name: "Alpha")
    for f in [PairFrame.pairCommit(r.commitment), r.reveal, .pairConfirm(Data([1, 2])), .pairReject] {
        let line = f.line().dropLast()
        #expect(try JSONDecoder().decode(PairFrame.self, from: line) == f)
    }
}

@Test func pairChannelSealsAndOpens() throws {
    let key = try rendezvous(PairRendezvous(id: "id-alpha", name: "Alpha"), PairRendezvous(id: "id-beta", name: "Beta")).a.key
    var sender = PairChannel(key: key, lower: true)
    var receiver = PairChannel(key: key, lower: false)
    let f1 = try sender.seal(Data("mark".utf8))
    #expect(try receiver.open(f1) == Data("mark".utf8))
    // Wiederholung wird abgewiesen, ein Frame mit fremdem Schlüssel auch
    #expect(throws: PairAuthError.rejected) { try receiver.open(f1) }
    var other = PairChannel(key: SymmetricKey(size: .bits256), lower: true)
    #expect(throws: PairAuthError.rejected) { try receiver.open(try other.seal(Data("x".utf8))) }
}
