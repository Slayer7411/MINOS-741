import CryptoKit
import Foundation
import MixCore
import Security

/// Pairing-Schlüssel je Partner: Keychain (generic password, Dienst „MINOS-741 pair“, Konto = Id des Partners).
/// Ende-zu-Ende: Datei `pair-keys.json` im Instanzordner, die Keychain bleibt unberührt.
enum PairKeychain {
    static let service = "MINOS-741 pair"

    static func get(_ peer: String) -> SymmetricKey? {
        if let root = E2E.root { return fileStore(root)[peer].map { SymmetricKey(data: $0) } }
        var q = query(peer)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return SymmetricKey(data: d)
    }

    static func set(_ key: SymmetricKey, for peer: String) {
        let data = PairCrypto.bytes(key)
        if let root = E2E.root {
            var m = fileStore(root)
            m[peer] = data
            saveFileStore(m, root)
            return
        }
        remove(peer)
        var q = query(peer)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }

    static func remove(_ peer: String) {
        if let root = E2E.root {
            var m = fileStore(root)
            m[peer] = nil
            saveFileStore(m, root)
            return
        }
        SecItemDelete(query(peer) as CFDictionary)
    }

    private static func query(_ peer: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: peer]
    }

    private static func fileURL(_ root: URL) -> URL { root.appendingPathComponent("pair-keys.json") }

    private static func fileStore(_ root: URL) -> [String: Data] {
        (try? Data(contentsOf: fileURL(root))).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
    }

    private static func saveFileStore(_ m: [String: Data], _ root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(m).write(to: fileURL(root), options: .atomic)
    }
}

/// Kennung dieses Macs für Kopplung und Handshake: zufällig beim ersten Start, nur lokal (Application Support, nicht
/// synchronisiert). Der Name (Bonjour, Anzeige) ist davon getrennt
enum PairIdentity {
    static let id: String = {
        let file = DataDir.local.appendingPathComponent("pair-instance-id")
        if let s = try? String(contentsOf: file, encoding: .utf8), !s.isEmpty { return s }
        let s = UUID().uuidString
        try? FileManager.default.createDirectory(at: DataDir.local, withIntermediateDirectories: true)
        try? s.write(to: file, atomically: true, encoding: .utf8)
        return s
    }()
}

/// Gekoppelte Macs (Liste, Modus je Mac). Alter Einzelpartner wird beim ersten Laden übernommen
enum PairedPeerStore {
    static func load() -> [PairedPeer] {
        let legacyID = E2E.defaults.string(forKey: "pair.peerID"), legacyName = E2E.defaults.string(forKey: "pair.peerName")
        let stored = E2E.defaults.data(forKey: "pair.peers").flatMap { try? JSONDecoder().decode([PairedPeer].self, from: $0) }
        let list = PairPeers.migrated(list: stored, legacyID: legacyID, legacyName: legacyName)
        if stored == nil, !list.isEmpty { save(list) }
        E2E.defaults.removeObject(forKey: "pair.peerID")
        E2E.defaults.removeObject(forKey: "pair.peerName")
        return list
    }

    static func save(_ list: [PairedPeer]) {
        E2E.defaults.set(try? JSONEncoder().encode(list), forKey: "pair.peers")
    }
}
