import CryptoKit
import Foundation

/// Zeile zwischen zwei Macs: Handshake (hello, proof) und danach versiegelte Nachrichten
public enum PairFrame: Codable, Equatable, Sendable {
    /// Id des Macs und eine Zufallsnonce (32 Byte)
    case hello(id: String, nonce: Data)
    /// HMAC über beide Ids und Nonces, mit der eigenen Id als Beweisender
    case proof(Data)
    /// ChaCha20-Poly1305 über eine PairMessage-Zeile; `seq` = Zähler der Richtung (ab 1), `box` = Chiffre + Tag
    case sealed(seq: UInt64, box: Data)

    public func line() -> Data {
        var d = (try? JSONEncoder().encode(self)) ?? Data()
        d.append(0x0A)
        return d
    }
}

public enum PairAuthError: Error, Equatable, Sendable {
    case rejected, unpaired
}

/// Schlüssel aus dem Pairing-Code; Handshake und versiegelte Frames
public enum PairCrypto {
    static let salt = Data("MINOS-741 pair v1".utf8)

    /// gemeinsamer Schlüssel der beiden Macs; die Reihenfolge der Ids spielt keine Rolle
    public static func deriveKey(code: String, idA: String, idB: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: salt,
                               info: Data([idA, idB].sorted().joined(separator: "\u{0}").utf8), outputByteCount: 32)
    }

    public static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
}

/// Handshake einer Verbindung: beide Seiten schicken hello, nach dem hello des anderen ihr proof; das proof des
/// anderen wird geprüft. Ergebnis: Sitzungsschlüssel aus Schlüssel und beiden Nonces.
public struct PairHandshake: Sendable {
    private let ownID: String
    private let nonce: Data
    private var key: SymmetricKey?
    public private(set) var peerID: String?
    private var peerNonce: Data?
    public private(set) var session: SymmetricKey?

    public init(ownID: String) {
        self.ownID = ownID
        nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    public var hello: PairFrame { .hello(id: ownID, nonce: nonce) }

    /// Verarbeitet ein empfangenes Frame; `keyFor` liefert den Schlüssel zum Partner (nil: nicht gekoppelt).
    /// Ergebnis: das zu sendende Frame (proof) oder nil. Fehler: Verbindung schließen.
    public mutating func receive(_ frame: PairFrame, key keyFor: (String) -> SymmetricKey?) throws -> PairFrame? {
        switch frame {
        case let .hello(id, n):
            guard peerID == nil, id != ownID, n.count == 32 else { throw PairAuthError.rejected }
            guard let k = keyFor(id) else { throw PairAuthError.unpaired }
            peerID = id
            peerNonce = n
            key = k
            return .proof(mac(prover: ownID))
        case let .proof(m):
            guard let id = peerID, let n = peerNonce, let k = key, session == nil else { throw PairAuthError.rejected }
            let s = sorted(id, n)
            guard HMAC<SHA256>.isValidAuthenticationCode(m, authenticating: Self.transcript(s, prover: id), using: k) else {
                throw PairAuthError.rejected
            }
            session = HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: s[0].nonce + s[1].nonce, info: Data("session".utf8),
                                             outputByteCount: 32)
            return nil
        case .sealed:
            throw PairAuthError.rejected
        }
    }

    /// Kanal nach erfolgreichem Handshake
    public func channel() -> PairChannel? {
        guard let session, let peer = peerID else { return nil }
        return PairChannel(key: session, lower: ownID < peer)
    }

    private func mac(prover: String) -> Data {
        guard let id = peerID, let n = peerNonce, let k = key else { return Data() }
        return Data(HMAC<SHA256>.authenticationCode(for: Self.transcript(sorted(id, n), prover: prover), using: k))
    }

    private func sorted(_ id: String, _ n: Data) -> [(id: String, nonce: Data)] {
        [(ownID, nonce), (id, n)].sorted { $0.id < $1.id }
    }

    static func transcript(_ parts: [(id: String, nonce: Data)], prover: String) -> Data {
        var d = Data("proof".utf8)
        for p in parts { d += Data(p.id.utf8) + Data([0]) + p.nonce }
        return d + Data(prover.utf8)
    }
}

/// Versiegelte Frames einer Verbindung. Nonce = Richtung (1 Byte, 0 = kleinere Id) + Zähler (8 Byte, big-endian);
/// der Empfänger nimmt nur Zähler über dem letzten gesehenen an.
public struct PairChannel: Sendable {
    private let key: SymmetricKey
    private let sendDir: UInt8
    private let recvDir: UInt8
    private var sent: UInt64 = 0
    private var seen: UInt64 = 0

    /// `lower`: dieser Mac hat die kleinere Id
    public init(key: SymmetricKey, lower: Bool) {
        self.key = key
        sendDir = lower ? 0 : 1
        recvDir = lower ? 1 : 0
    }

    public mutating func seal(_ plain: Data) throws -> PairFrame {
        sent += 1
        let box = try ChaChaPoly.seal(plain, using: key, nonce: Self.nonce(sendDir, sent))
        return .sealed(seq: sent, box: box.ciphertext + box.tag)
    }

    public mutating func open(_ frame: PairFrame) throws -> Data {
        guard case let .sealed(seq, body) = frame, seq > seen, body.count >= 16 else { throw PairAuthError.rejected }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(recvDir, seq), ciphertext: Data(body.dropLast(16)),
                                               tag: Data(body.suffix(16)))
            let plain = try ChaChaPoly.open(box, using: key)
            seen = seq
            return plain
        } catch {
            throw PairAuthError.rejected
        }
    }

    private static func nonce(_ dir: UInt8, _ counter: UInt64) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data([0, 0, 0, dir]) + withUnsafeBytes(of: counter.bigEndian) { Data($0) })
    }
}
