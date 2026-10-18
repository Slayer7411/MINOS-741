import CryptoKit
import Foundation

/// Zeile zwischen zwei Macs: Kopplung (Festlegung, Aufdeckung, Bestätigung), danach Handshake und versiegelte Nachrichten
public enum PairFrame: Codable, Equatable, Sendable {
    /// Kopplung: SHA256 über Id, Name, öffentlichen Schlüssel und Nonce (Festlegung vor dem Aufdecken)
    case pairCommit(Data)
    /// Kopplung: Aufdeckung – Id, Name, X25519-Schlüssel (32 Byte), Nonce (32 Byte)
    case pairReveal(id: String, name: String, pub: Data, nonce: Data)
    /// Kopplung: Bestätigung (HMAC mit dem gemeinsamen Schlüssel) über die eigene Id
    case pairConfirm(Data)
    /// Kopplung: abgebrochen oder abgelehnt
    case pairReject
    /// Handshake: stabile Id, Name (nur Anzeige) und Zufallsnonce (32 Byte)
    case hello(id: String, name: String, nonce: Data)
    /// Handshake: HMAC über beide Ids und Nonces, mit der eigenen Id als Beweisender
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
    case rejected, unpaired, commitmentMismatch
}

/// Kopplung ohne geheimen Code: beide Macs legen sich auf einen X25519-Schlüssel und eine Nonce fest (Commit),
/// decken auf (Reveal), leiten daraus den Schlüssel und eine 6-stellige Zahl ab (SAS). Die Nutzer vergleichen die
/// Zahl. Eine Aufzeichnung der Kopplung enthält kein Geheimnis mit geringer Entropie.
public struct PairRendezvous: Sendable {
    public let ownID: String
    public let ownName: String
    private let priv: Curve25519.KeyAgreement.PrivateKey
    private let nonce: Data

    public init(id: String, name: String) {
        ownID = id
        ownName = name
        priv = Curve25519.KeyAgreement.PrivateKey()
        nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    public var publicKey: Data { priv.publicKey.rawRepresentation }

    /// Festlegung, die vor dem Aufdecken gesendet wird
    public var commitment: Data { Self.commit(id: ownID, name: ownName, pub: publicKey, nonce: nonce) }

    public var reveal: PairFrame { .pairReveal(id: ownID, name: ownName, pub: publicKey, nonce: nonce) }

    /// Prüft Festlegung und Aufdeckung des Partners; Ergebnis: Sitzungsschlüssel und Vergleichszahl
    public func finish(peerCommit: Data, reveal: PairFrame) throws -> PairSAS {
        guard case let .pairReveal(id, name, pub, n) = reveal, id != ownID, pub.count == 32, n.count == 32 else {
            throw PairAuthError.rejected
        }
        guard Self.commit(id: id, name: name, pub: pub, nonce: n) == peerCommit else { throw PairAuthError.commitmentMismatch }
        let shared = try priv.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub))
        // Transkript in fester Reihenfolge (nach Id), damit beide Macs dieselben Bytes hashen
        let parts = [(ownID, ownName, publicKey, nonce), (id, name, pub, n)].sorted { $0.0 < $1.0 }
        var t = Data("MINOS-741 pair v2".utf8)
        for p in parts { t += Self.field(p.0) + Self.field(p.1) + p.2 + p.3 }
        let transcript = Data(SHA256.hash(data: t))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
                                                 sharedInfo: Data("MINOS-741 pair key".utf8), outputByteCount: 32)
        let digest = Data(SHA256.hash(data: transcript + Data("code".utf8)))
        let number = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        return PairSAS(key: key, code: String(format: "%06llu", number), transcript: transcript)
    }

    static func commit(id: String, name: String, pub: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("MINOS-741 pair commit".utf8) + field(id) + field(name) + pub + nonce))
    }

    /// Länge (2 Byte) und Text, damit Felder nicht ineinander übergehen
    static func field(_ s: String) -> Data {
        let b = Data(s.utf8)
        return withUnsafeBytes(of: UInt16(b.count).bigEndian) { Data($0) } + b
    }
}

/// Ergebnis einer Kopplung: gemeinsamer Schlüssel (32 Byte) und die 6-stellige Zahl zum Vergleich
public struct PairSAS: Sendable {
    public let key: SymmetricKey
    public let code: String
    let transcript: Data

    /// Bestätigung des Macs mit dieser Id
    public func confirmation(from id: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript + Data("confirm".utf8) + Data(id.utf8), using: key))
    }

    public func verify(_ mac: Data, from id: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: transcript + Data("confirm".utf8) + Data(id.utf8), using: key)
    }
}

public enum PairCrypto {
    public static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
}

/// Handshake einer Verbindung mit dem gekoppelten Schlüssel: beide Seiten schicken hello, nach dem hello des anderen
/// ihr proof; das proof des anderen wird geprüft. Ergebnis: Sitzungsschlüssel aus Schlüssel und beiden Nonces.
public struct PairHandshake: Sendable {
    private let ownID: String
    private let ownName: String
    private let nonce: Data
    private var key: SymmetricKey?
    public private(set) var peerID: String?
    private var peerNonce: Data?
    public private(set) var session: SymmetricKey?

    public init(ownID: String, ownName: String) {
        self.ownID = ownID
        self.ownName = ownName
        nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    public var hello: PairFrame { .hello(id: ownID, name: ownName, nonce: nonce) }

    /// Verarbeitet ein empfangenes Frame; `keyFor` liefert den Schlüssel zum Partner (nil: nicht gekoppelt).
    /// Ergebnis: das zu sendende Frame (proof) oder nil. Fehler: Verbindung schließen.
    public mutating func receive(_ frame: PairFrame, key keyFor: (String) -> SymmetricKey?) throws -> PairFrame? {
        switch frame {
        case let .hello(id, _, n):
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
        case .pairCommit, .pairReveal, .pairConfirm, .pairReject, .sealed:
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
