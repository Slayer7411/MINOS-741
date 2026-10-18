import Foundation
import Testing
@testable import MixCore

@Test func pairMessageRoundTripInChunks() {
    let msgs: [PairMessage] = [
        .hello(writes: true, decks: [0, 2], version: PairMessage.version, name: "Mac 1", played: ["a", "b"]),
        .playedSet(["a", "b", "c"]),
        .played(add: ["x"], remove: ["a"]),
        .state(writes: false, decks: [1, 3]),
        .live(true),
    ]
    var stream = Data()
    for m in msgs { stream.append(m.line()) }
    var r = PairLineReader<PairMessage>()
    var got: [PairMessage] = []
    var i = stream.startIndex
    while i < stream.endIndex {
        let j = min(stream.endIndex, i + 7)
        got += r.feed(stream[i..<j])
        i = j
    }
    #expect(got == msgs)
}

@Test func pairReaderSkipsBrokenLines() {
    var r = PairLineReader<PairMessage>()
    var d = Data("kaputt\n".utf8)
    d.append(PairMessage.played(add: ["k"], remove: []).line())
    #expect(r.feed(d) == [.played(add: ["k"], remove: [])])
}

@Test func pairPlayedMergeKeepsBoth() {
    #expect(PairPlayed.merged(["a"], ["b"]) == ["a", "b"])
}

@Test func pairCheckOneWriterNoSharedDeck() {
    #expect(PairCheck.problems(ownWrites: true, ownDecks: [0, 2], peerWrites: false, peerDecks: [1, 3]).isEmpty)
    #expect(PairCheck.problems(ownWrites: true, ownDecks: [0], peerWrites: true, peerDecks: [1]) == [.bothWrite])
    #expect(PairCheck.problems(ownWrites: false, ownDecks: [0, 1], peerWrites: false, peerDecks: [1, 3]) == [.noneWrites, .sharedDecks([1])])
}

@Test func pairDebugMessagesRoundTrip() {
    let msgs: [PairMessage] = [
        .debugRequest(id: 1_800_000_001, command: "prefs-set", args: #"{"ui":{"zoom":1.2}}"#),
        .debugReply(id: 1_800_000_001, ok: false, body: "\"Fernzugriff aus\""),
        .debugReply(id: 2, ok: true, body: #"{"name":"Mac 2"}"#),
    ]
    var stream = Data()
    for m in msgs { stream.append(m.line()) }
    var r = PairLineReader<PairMessage>()
    #expect(r.feed(stream) == msgs)
    #expect(PairMessage.version == 6)
}

@Test func pairClockMessageRoundTrip() {
    let msgs: [PairMessage] = [.clock(playingMaster: true, leader: false), .clock(playingMaster: false, leader: true)]
    var r = PairLineReader<PairMessage>()
    var stream = Data()
    for m in msgs { stream.append(m.line()) }
    #expect(r.feed(stream) == msgs)
    #expect(PairMessage.version == 6)
}
