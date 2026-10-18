import Foundation

/// Existenz von Dateien für Stellen auf dem Hauptthread (Ansichten, Menüs). Ein `stat` auf einem Cloud-Ordner
/// (Google Drive, iCloud) kann Sekunden hängen: der Hauptthread liest nur den Zwischenspeicher, `refresh` prüft
/// auf einer eigenen Queue und füllt ihn.
public final class FileStatCache: @unchecked Sendable {
    public static let shared = FileStatCache()

    private let lock = NSLock()
    private var entries: [String: (exists: Bool, at: Date)] = [:]
    private let queue = DispatchQueue(label: "minos741.filestat", qos: .utility)
    private let statter: @Sendable (String) -> Bool
    /// wie lange ein Ergebnis gilt (Sekunden); danach gilt der Pfad als unbekannt
    public let maxAge: TimeInterval

    public init(maxAge: TimeInterval = 60, statter: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.maxAge = maxAge
        self.statter = statter
    }

    /// Nur Zwischenspeicher, nie ein Dateizugriff. nil = noch nicht geprüft oder veraltet
    public func cached(_ path: String) -> Bool? {
        lock.withLock {
            guard let e = entries[path], Date().timeIntervalSince(e.at) <= maxAge else { return nil }
            return e.exists
        }
    }

    /// Prüft `paths` auf der Hintergrund-Queue und merkt sich die Ergebnisse; `done` danach auf dem Hauptthread
    public func refresh(_ paths: [String], done: (@Sendable () -> Void)? = nil) {
        let unique = Array(Set(paths))
        queue.async {
            let results = unique.map { ($0, self.statter($0)) }
            let now = Date()
            self.lock.withLock { for (p, ok) in results { self.entries[p] = (ok, now) } }
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }
}
