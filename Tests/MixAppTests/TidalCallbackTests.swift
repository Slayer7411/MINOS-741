import Foundation
import Testing
@testable import MixApp

// TIDAL-Rücksprung: der Listener nimmt 127.0.0.1, ::1 und localhost an, nur auf Loopback. Kein Browser, kein Netz zu TIDAL.

@Test func callbackRedirectMatchesListener() {
    #expect(TidalAuth.redirectURI == "http://localhost:\(TidalAuth.callbackPort)/tidal/callback")
}

@Test func callbackListenerAcceptsIPv4IPv6AndLocalhost() async throws {
    for host in ["127.0.0.1", "[::1]", "localhost"] {
        let server = TidalCallbackServer(port: 0)
        let (results, cont) = AsyncStream.makeStream(of: Result<[String: String], Error>.self)
        try server.start(timeout: 10) { cont.yield($0); cont.finish() }
        #expect(server.hosts == ["127.0.0.1", "::1"])
        var req = URLRequest(url: try #require(URL(string: "http://\(host):\(server.port)/tidal/callback?code=c1&state=s1")))
        req.timeoutInterval = 5
        let (_, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200, "\(host)")
        var got: [String: String]?
        for await r in results {
            got = try? r.get()
            break
        }
        #expect(got?["code"] == "c1" && got?["state"] == "s1", "\(host)")
    }
}

@Test func callbackListenerIgnoresOtherPaths() async throws {
    let server = TidalCallbackServer(port: 0)
    let (results, cont) = AsyncStream.makeStream(of: Result<[String: String], Error>.self)
    try server.start(timeout: 10) { cont.yield($0); cont.finish() }
    var req = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(server.port)/other?code=c1")))
    req.timeoutInterval = 5
    let (_, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
    #expect((resp as? HTTPURLResponse)?.statusCode == 404)
    server.stop(TidalError.cancelled)
    for await r in results {
        if case .success = r { Issue.record("Pfad falsch angenommen") }
        break
    }
}

@Test func callbackTimeoutHasClearMessage() async throws {
    let server = TidalCallbackServer(port: 0)
    let (results, cont) = AsyncStream.makeStream(of: Result<[String: String], Error>.self)
    try server.start(timeout: 0.2) { cont.yield($0); cont.finish() }
    var failure: Error?
    for await r in results {
        if case let .failure(e) = r { failure = e }
        break
    }
    guard case .timeout? = failure as? TidalError else { Issue.record("kein Zeitlimit: \(String(describing: failure))"); return }
    let text = (failure as? LocalizedError)?.errorDescription ?? ""
    #expect(text.contains("5 Min."))
}

@Test func callbackPortInUseIsReported() throws {
    let first = TidalCallbackServer(port: 0)
    try first.start(timeout: 10) { _ in }
    defer { first.stop(TidalError.cancelled) }
    let second = TidalCallbackServer(port: first.port)
    #expect(throws: TidalError.self) { try second.start(timeout: 10) { _ in } }
}
