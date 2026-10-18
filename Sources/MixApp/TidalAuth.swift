import AppKit
import CryptoKit
import Foundation
import Security

/// TIDAL-Anmeldung: OAuth 2.0 Authorization Code mit PKCE für einen öffentlichen Client (kein Client-Secret).
/// Quellen: Sicherheitsschema „Authorization_Code_PKCE“ der API-Referenz (tidal-music.github.io/tidal-api-reference,
/// tidal-api-oas.json: login.tidal.com/authorize, auth.tidal.com/v1/oauth2/token) und developer.tidal.com.
/// Tokens nur im Schlüsselbund, nie in Logs oder Statusmeldungen.
enum TidalAuth {
    static let authorizeEndpoint = "https://login.tidal.com/authorize"
    static let tokenEndpoint = "https://auth.tidal.com/v1/oauth2/token"
    static let redirectURI = "http://localhost:7412/tidal/callback"
    static let callbackPort: UInt16 = 7412
    /// user.read (Land), playlists.read/write, search.read: die vom TIDAL-Portal freigegebenen Scopes (Stand Registrierung)
    /// r_usr/w_usr stehen im Schema der Referenz, sind aber INTERNAL und nicht freigegeben
    static let scopes = ["user.read", "playlists.read", "playlists.write", "search.read"]
    /// Wartezeit im Browser, danach bricht die Anmeldung ab
    static let timeout: TimeInterval = 300

    static var signedIn: Bool { TidalKeychain.load() != nil }

    static func signOut() { TidalKeychain.delete() }

    /// Anmeldung: Browser öffnen, Rücksprung auf 127.0.0.1 abwarten, Code gegen Tokens tauschen, im Schlüsselbund speichern
    static func signIn(clientID: String) async throws -> TidalTokens {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw TidalError.noClientID }
        let verifier = TidalPKCE.verifier()
        let state = TidalPKCE.verifier()
        guard let url = authorizeURL(clientID: id, challenge: TidalPKCE.challenge(verifier), state: state) else {
            throw TidalError.badResponse
        }
        let server = TidalCallbackServer()
        let query: [String: String] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
                do {
                    try server.start(timeout: timeout) { c.resume(with: $0) }
                } catch {
                    c.resume(throwing: error)
                    return
                }
                Task { @MainActor in _ = NSWorkspace.shared.open(url) }
            }
        } onCancel: {
            server.stop(TidalError.cancelled)
        }
        guard query["state"] == state else { throw TidalError.state }
        if let e = query["error"] { throw TidalError.denied(e) }
        guard let code = query["code"] else { throw TidalError.badResponse }
        let data = try await postToken(form([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
            ("client_id", id), ("code_verifier", verifier),
        ]))
        let t = try tokens(from: data)
        _ = TidalKeychain.save(t)
        return t
    }

    /// neuer Access-Token über den Refresh-Token; das Ergebnis wird gespeichert
    static func refresh(_ t: TidalTokens, clientID: String) async throws -> TidalTokens {
        let data = try await postToken(form([
            ("grant_type", "refresh_token"), ("refresh_token", t.refresh), ("client_id", clientID),
        ]))
        let n = try tokens(from: data, keepRefresh: t.refresh)
        _ = TidalKeychain.save(n)
        return n
    }

    static func authorizeURL(clientID: String, challenge: String, state: String) -> URL? {
        var c = URLComponents(string: authorizeEndpoint)
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return c?.url
    }

    /// Antwort des Token-Endpunkts; ohne neuen Refresh-Token bleibt der alte
    static func tokens(from data: Data, now: Date = Date(), keepRefresh: String? = nil) throws -> TidalTokens {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let r = try d.decode(TokenResponse.self, from: data)
        guard let refresh = r.refreshToken ?? keepRefresh else { throw TidalError.badResponse }
        return TidalTokens(access: r.accessToken, refresh: refresh, expires: now.addingTimeInterval(r.expiresIn ?? 3600))
    }

    /// application/x-www-form-urlencoded
    static func form(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let s = fields.map { k, v in
            [k, v].map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "=")
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
    }

    private static func postToken(_ body: Data) async throws -> Data {
        guard let url = URL(string: tokenEndpoint) else { throw TidalError.badResponse }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = body
        r.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw TidalError.http(code, TidalClient.errorDetail(data)) }
        return data
    }
}

/// Tokens im Schlüsselbund (Dienst „MINOS-741 TIDAL“)
struct TidalTokens: Codable, Equatable, Sendable {
    var access: String
    var refresh: String
    var expires: Date
    /// mit einer Minute Reserve gültig
    var fresh: Bool { expires.timeIntervalSinceNow > 60 }
}

enum TidalKeychain {
    static let service = "MINOS-741 TIDAL"

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "tokens"]
    }

    static func load() -> TidalTokens? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(TidalTokens.self, from: d)
    }

    @discardableResult
    static func save(_ t: TidalTokens) -> Bool {
        guard let d = try? JSONEncoder().encode(t) else { return false }
        delete()
        var q = query()
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(query() as CFDictionary) }
}

/// PKCE nach RFC 7636 (Verfahren S256)
enum TidalPKCE {
    /// zufälliger Verifier: 32 Byte, base64url ohne Auffüllung (43 Zeichen)
    static func verifier() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return base64url(Data(b))
    }

    static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum TidalError: LocalizedError {
    case noClientID
    case http(Int, String)
    case badResponse
    case state
    case denied(String)
    case timeout
    case portBusy
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noClientID: String(localized: "Client-ID fehlt (⌘, → Browser)")
        case let .http(code, detail):
            switch code {
            case 401: String(localized: "nicht angemeldet – erneut anmelden")
            case 403: String(localized: "Zugriff verweigert (Scopes der App prüfen)")
            case 429: String(localized: "Ratenlimit erreicht")
            default: "HTTP \(code)" + (detail.isEmpty ? "" : " · \(detail)")
            }
        case .badResponse: String(localized: "Antwort von TIDAL unlesbar")
        case .state: String(localized: "Anmeldung abgelehnt (state stimmt nicht)")
        case let .denied(e): String(localized: "Anmeldung abgelehnt: \(e)")
        case .timeout: String(localized: "Anmeldung abgelaufen: keine Antwort aus dem Browser in 5 Min. – erneut ANMELDEN")
        case .portBusy: String(localized: "Port 7412 belegt: andere Anmeldung läuft noch")
        case .cancelled: String(localized: "abgebrochen")
        }
    }
}

/// Einmaliger Empfang des Rücksprungs: nur Loopback, Pfad /tidal/callback; danach Antwortseite und Ende.
/// Ein Socket je Loopback-Adresse (127.0.0.1 und ::1), nie an alle Schnittstellen: localhost löst der Browser
/// je nach Einstellung auf eine der beiden auf.
final class TidalCallbackServer: @unchecked Sendable {
    static let loopbackHosts = ["127.0.0.1", "::1"]
    private let queue = DispatchQueue(label: "minos.tidal.callback")
    private let wantedPort: UInt16
    /// Port nach `start` (bei 0 der gewählte) und die gebundenen Adressen
    private(set) var port: UInt16 = 0
    private(set) var hosts: [String] = []
    /// nur auf `queue`
    private var listeners: [DispatchSourceRead] = []
    /// nur auf `queue`
    private var finish: ((Result<[String: String], Error>) -> Void)?

    private enum Bind { case open(Int32), inUse, unavailable }

    init(port: UInt16 = TidalAuth.callbackPort) { wantedPort = port }

    /// Sockets öffnen (sofort lauschend); ohne eine Adresse oder bei belegtem Port ein Fehler
    func start(timeout: TimeInterval, _ done: @escaping (Result<[String: String], Error>) -> Void) throws {
        var fds: [(fd: Int32, host: String)] = []
        var p = wantedPort
        for host in Self.loopbackHosts {
            switch Self.openListener(host, port: p) {
            case let .open(fd):
                if p == 0 { p = Self.localPort(fd) }
                fds.append((fd, host))
            case .inUse:
                fds.forEach { close($0.fd) }
                throw TidalError.portBusy
            case .unavailable:
                continue
            }
        }
        guard !fds.isEmpty else { throw TidalError.portBusy }
        queue.sync {
            finish = done
            port = p
            hosts = fds.map(\.host)
            listeners = fds.map { l in
                let src = DispatchSource.makeReadSource(fileDescriptor: l.fd, queue: queue)
                src.setEventHandler { [weak self] in self?.accept(l.fd) }
                src.setCancelHandler { close(l.fd) }
                src.resume()
                return src
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(.failure(TidalError.timeout)) }
    }

    func stop(_ e: Error) {
        queue.async { [weak self] in self?.end(.failure(e)) }
    }

    /// nur auf `queue`
    private func end(_ r: Result<[String: String], Error>) {
        guard let f = finish else { return }
        finish = nil
        listeners.forEach { $0.cancel() }
        listeners = []
        f(r)
    }

    /// nur auf `queue`: die Anfrage wird auf einem eigenen Thread gelesen, damit eine langsame Verbindung nicht aufhält
    private func accept(_ lfd: Int32) {
        let cfd = Darwin.accept(lfd, nil, nil)
        guard cfd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let target = Self.requestTarget(cfd)
            guard URLComponents(string: "http://127.0.0.1" + target)?.path == "/tidal/callback" else {
                Self.respond(cfd, status: "404 Not Found", body: "")
                return
            }
            var q: [String: String] = [:]
            for i in URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? [] {
                if let v = i.value { q[i.name] = v }
            }
            let ok = q["code"] != nil
            Self.respond(cfd, status: "200 OK", body: ok
                ? "<!doctype html><meta charset=utf-8><title>MINOS-741</title><p style=\"font-family:-apple-system\">MINOS-741: angemeldet, Fenster schließen</p>"
                : "<!doctype html><meta charset=utf-8><title>MINOS-741</title><p style=\"font-family:-apple-system\">MINOS-741: Anmeldung abgebrochen, Fenster schließen</p>")
            if ok || q["error"] != nil { self?.queue.async { self?.end(.success(q)) } }
        }
    }

    /// Ziel der Anfrage („/tidal/callback?code=…“); Zeitlimit für Lesen, sonst leer
    private static func requestTarget(_ fd: Int32) -> String {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 8192)
        let cap = buf.count
        var n = 0
        while n < cap {
            let k = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + n, cap - n) }
            if k <= 0 { break }
            n += k
            if buf[..<n].contains(10) { break }
        }
        let line = String(decoding: buf[..<n], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    private static func respond(_ fd: Int32, status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        let bytes = Array((head + body).utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    private static func openListener(_ host: String, port: UInt16) -> Bind {
        let v6 = host.contains(":")
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable }
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
        if v6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, size) }
        let r: Int32
        if v6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            _ = inet_pton(AF_INET6, host, &a.sin6_addr)
            r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            _ = inet_pton(AF_INET, host, &a.sin_addr)
            r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard r == 0, Darwin.listen(fd, 4) == 0 else {
            let inUse = errno == EADDRINUSE
            close(fd)
            return inUse ? .inUse : .unavailable
        }
        return .open(fd)
    }

    private static func localPort(_ fd: Int32) -> UInt16 {
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: a.sin_port)
    }
}
