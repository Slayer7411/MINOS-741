import Foundation
import Testing
@testable import MixCore

/// zwei Handshakes mit Schlüsseln aus `codeA` / `codeB`; liefert beide nach dem Austausch aller Frames
private func handshake(codeA: String, codeB: String) throws -> (a: PairHandshake, b: PairHandshake, pa: PairFrame?, pb: PairFrame?) {
    var a = PairHandshake(key: PairCrypto.deriveKey(code: codeA, idA: "Alpha", idB: "Beta"), ownID: "Alpha")
    var b = PairHandshake(key: PairCrypto.deriveKey(code: codeB, idA: "Alpha", idB: "Beta"), ownID: "Beta")
    let ha = a.hello, hb = b.hello
    let pa = try a.receive(hb)
    let pb = try b.receive(ha)
    return (a, b, pa, pb)
}

@Test func pairHandshakeSameCodeAgreesOnSessionKey() throws {
    var (a, b, pa, pb) = try handshake(codeA: "123456", codeB: "123456")
    #expect(try a.receive(try #require(pb)) == nil)
    #expect(try b.receive(try #require(pa)) == nil)
    let sa = try #require(a.session), sb = try #require(b.session)
    #expect(PairCrypto.bytes(sa) == PairCrypto.bytes(sb))
    #expect(PairCrypto.bytes(sa) != PairCrypto.bytes(PairCrypto.deriveKey(code: "123456", idA: "Alpha", idB: "Beta")))
}

@Test func pairHandshakeWrongCodeFails() throws {
    var (a, b, pa, pb) = try handshake(codeA: "123456", codeB: "654321")
    #expect(throws: PairAuthError.rejected) { try a.receive(try #require(pb)) }
    #expect(throws: PairAuthError.rejected) { try b.receive(try #require(pa)) }
    #expect(a.session == nil && b.session == nil)
}

@Test func pairHandshakeRejectsReplayedProofAndBadHello() throws {
    var (a, b, _, pb) = try handshake(codeA: "123456", codeB: "123456")
    _ = try a.receive(try #require(pb))
    #expect(throws: PairAuthError.rejected) { try a.receive(try #require(pb)) }
    #expect(throws: PairAuthError.rejected) { try b.receive(.hello(id: "Beta", nonce: Data(count: 32))) }
    #expect(throws: PairAuthError.rejected) { try b.receive(.hello(id: "Gamma", nonce: Data(count: 8))) }
}

@Test func pairKeyIndependentOfIdOrder() {
    let ab = PairCrypto.deriveKey(code: "123456", idA: "Alpha", idB: "Beta")
    let ba = PairCrypto.deriveKey(code: "123456", idA: "Beta", idB: "Alpha")
    #expect(PairCrypto.bytes(ab) == PairCrypto.bytes(ba))
    #expect(PairCrypto.bytes(ab) != PairCrypto.bytes(PairCrypto.deriveKey(code: "123457", idA: "Alpha", idB: "Beta")))
}

@Test func pairChannelRoundTripBothDirections() throws {
    let key = PairCrypto.deriveKey(code: "123456", idA: "Alpha", idB: "Beta")
    var lower = PairChannel(key: key, lower: true)
    var upper = PairChannel(key: key, lower: false)
    let f1 = try lower.seal(Data("one".utf8))
    #expect(try upper.open(f1) == Data("one".utf8))
    let f2 = try upper.seal(Data("two".utf8))
    #expect(try lower.open(f2) == Data("two".utf8))
}

@Test func pairChannelRejectsReplay() throws {
    let key = PairCrypto.deriveKey(code: "123456", idA: "Alpha", idB: "Beta")
    var sender = PairChannel(key: key, lower: true)
    var receiver = PairChannel(key: key, lower: false)
    let f1 = try sender.seal(Data("play".utf8))
    let f2 = try sender.seal(Data("pause".utf8))
    #expect(try receiver.open(f2) == Data("pause".utf8))
    #expect(throws: PairAuthError.rejected) { try receiver.open(f2) }
    #expect(throws: PairAuthError.rejected) { try receiver.open(f1) }
}

@Test func pairChannelRejectsTampering() throws {
    let key = PairCrypto.deriveKey(code: "123456", idA: "Alpha", idB: "Beta")
    var sender = PairChannel(key: key, lower: true)
    var receiver = PairChannel(key: key, lower: false)
    guard case let .sealed(seq, box) = try sender.seal(Data("mark".utf8)) else { throw PairAuthError.rejected }
    #expect(box.count == 4 + 16)
    var bent = box
    bent[bent.startIndex] ^= 0x01
    #expect(throws: PairAuthError.rejected) { try receiver.open(.sealed(seq: seq, box: bent)) }
    #expect(throws: PairAuthError.rejected) { try receiver.open(.sealed(seq: seq + 5, box: box)) }
    #expect(try receiver.open(.sealed(seq: seq, box: box)) == Data("mark".utf8))
}

@Test func pairChannelWithWrongKeyFails() throws {
    var sender = PairChannel(key: PairCrypto.deriveKey(code: "123456", idA: "Alpha", idB: "Beta"), lower: true)
    var receiver = PairChannel(key: PairCrypto.deriveKey(code: "654321", idA: "Alpha", idB: "Beta"), lower: false)
    #expect(throws: PairAuthError.rejected) { try receiver.open(try sender.seal(Data("x".utf8))) }
}
