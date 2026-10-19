import Foundation

/// Sicherungen der Collection-Datei im Ordner `Backup MINOS-741` neben der Datei: Auflistung, Prüfung und
/// Wiederherstellung. Reine Dateiarbeit (ohne Oberfläche, ohne Collection-Software).
public enum CollectionBackups {
    public static let folderName = "Backup MINOS-741"

    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { url.lastPathComponent }
        public let url: URL
        /// Zeitpunkt aus dem Dateinamen (`collection_JJJJ-MM-TT_HHMMSS.nml`)
        public let date: Date
        public let bytes: Int
    }

    public enum Failure: Error, Equatable {
        /// Die Sicherung ist keine lesbare Collection (Grund in Klartext)
        case invalid(String)
        /// Der bisherige Stand konnte nicht gesichert werden (z. B. gleiche Sekunde schon belegt): nichts ersetzt
        case previousNotBacked
    }

    /// Sicherungsordner zu einer Collection-Datei
    public static func folder(for collection: URL) -> URL {
        collection.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    }

    /// Sicherungen im Ordner, neueste zuerst. Andere Dateien bleiben unberücksichtigt
    public static func list(in dir: URL) -> [Entry] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> Entry? in
            guard name.hasPrefix("collection_"), name.hasSuffix(".nml"),
                  let date = CollectionWriter.backupFormatter.date(from: String(name.dropFirst("collection_".count).dropLast(4)))
            else { return nil }
            let url = dir.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return Entry(url: url, date: date, bytes: (attrs?[.size] as? Int) ?? 0)
        }
        .sorted { $0.date > $1.date }
    }

    /// Prüft Inhalt einer Sicherung: lesbares NML mit Collection-Element. Liefert die Trackzahl
    public static func validate(_ data: Data) throws -> Int {
        guard let text = String(data: data, encoding: .utf8), text.contains("<NML"), text.contains("<COLLECTION") else {
            throw Failure.invalid("keine Collection-Datei (NML)")
        }
        do {
            return try NMLParser.parse(data: data).tracks.count
        } catch {
            throw Failure.invalid("Datei lässt sich nicht lesen: \(error.localizedDescription)")
        }
    }

    /// Trackzahl einer Sicherung (liest die Datei); nil, wenn sie nicht gültig ist
    public static func trackCount(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? validate(data)
    }

    /// Sicherung des aktuellen Stands jetzt (ohne Mindestabstand). Nil, wenn die Datei fehlt oder die Sekunde belegt ist
    @discardableResult
    public static func backupNow(_ collection: URL, now: Date = Date()) throws -> URL? {
        guard FileManager.default.fileExists(atPath: collection.path) else { return nil }
        return try CollectionWriter.backup(collection, into: folder(for: collection), now: now, minInterval: 0)
    }

    /// Sicherung prüfen, den bisherigen Stand sichern, dann die Sicherung atomar an die Stelle der Collection setzen.
    /// Gibt Trackzahl der Sicherung und den Pfad der Sicherung des bisherigen Stands zurück (nil, wenn es keinen gab).
    /// Scheitert die Sicherung des bisherigen Stands (Sekunde belegt durch anderen Stand), wird nichts ersetzt
    @discardableResult
    public static func restore(_ backup: URL, over collection: URL, now: Date = Date()) throws -> (tracks: Int, previous: URL?) {
        let data: Data
        do { data = try Data(contentsOf: backup) } catch { throw Failure.invalid("Sicherung nicht lesbar") }
        let tracks = try validate(data)
        // Sperre wie beim Schreiben der Collection: kein Schreiben dazwischen
        return try CollectionWriter.withLock(collection) {
            var previous: URL?
            let fm = FileManager.default
            if fm.fileExists(atPath: collection.path) {
                let dir = folder(for: collection)
                if let p = try CollectionWriter.backup(collection, into: dir, now: now, minInterval: 0) {
                    previous = p
                } else {
                    // gleiche Sekunde wie eine Sicherung: ist sie der bisherige Stand, reicht sie; sonst nichts ersetzen
                    let same = dir.appendingPathComponent("collection_\(CollectionWriter.backupFormatter.string(from: now)).nml")
                    // beide Dateien müssen lesbar sein: nil == nil wäre sonst "gleich" und die Datei würde ungeprüft ersetzt
                    var isSame = false
                    if fm.fileExists(atPath: same.path) { isSame = try Data(contentsOf: same) == Data(contentsOf: collection) }
                    guard isSame else { throw Failure.previousNotBacked }
                    previous = same
                }
            }
            try CollectionWriter.replaceAtomically(collection, with: data)
            return (tracks, previous)
        }
    }
}
