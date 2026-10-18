import Foundation
import Testing
import MixCore
@testable import MixApp

@Test func pairDebugRequestFileParses() throws {
    let plain = Data(#"{"command":"ping","args":"","token":"t1"}"#.utf8)
    #expect(PairDebugFile.request(plain) == PairDebugFile.Request(command: "ping", args: "", token: "t1"))
    // args als Objekt: wird als JSON-Text weitergegeben
    let obj = Data(#"{"command":"prefs-set","args":{"ui":{"zoom":1.2}}}"#.utf8)
    let r = try #require(PairDebugFile.request(obj))
    #expect(r.token == nil)
    #expect(r.args == #"{"ui":{"zoom":1.2}}"#)
    #expect(PairDebugFile.request(Data(#"{"args":"x"}"#.utf8)) == nil)
    #expect(PairDebugFile.request(Data("kaputt".utf8)) == nil)
}

@Test func pairDebugInboxNameIsSafe() {
    #expect(PairDebugFile.inboxName(id: 7, command: "defaults-get") == "7-defaults-get.json")
    #expect(PairDebugFile.inboxName(id: 7, command: "a/b c") == "7-a_b_c.json")
}

@Test func pairDebugReplyParsesBodyJSON() throws {
    let data = PairDebugFile.reply(id: 3, ok: true, command: "ping", peer: "Mac 2", body: #"{"build":"42"}"#, token: "tok")
    let o = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(o["id"] as? Int == 3)
    #expect(o["ok"] as? Bool == true)
    #expect(o["command"] as? String == "ping")
    #expect(o["peer"] as? String == "Mac 2")
    #expect(o["token"] as? String == "tok")
    #expect((o["body"] as? [String: Any])?["build"] as? String == "42")
    #expect(o["at"] == nil)
}

@Test func pairDebugReplyKeepsBodyTextWhenNotJSON() throws {
    let data = PairDebugFile.reply(id: 4, ok: false, command: "ping", peer: nil, body: "keine Verbindung", token: nil)
    let o = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(o["body"] as? String == "keine Verbindung")
    #expect(o["peer"] is NSNull)
    #expect(o["token"] == nil)
}

@Test func pairSetupRemoteDebugDefaultsOffAndDecodesTolerant() throws {
    #expect(!PairSetup().remoteDebug)
    let old = try JSONDecoder().decode(PairSetup.self, from: Data(#"{"on":true,"writes":false,"decks":[1,3]}"#.utf8))
    #expect(!old.remoteDebug && old.on && !old.writes && old.decks == [1, 3])
    let on = try JSONDecoder().decode(PairSetup.self, from: Data(#"{"remoteDebug":true}"#.utf8))
    #expect(on.remoteDebug)
}
