import Foundation

/// Welche Pfade es gibt, auf einer Hintergrund-Queue (ein stat auf einem Cloud-Ordner kann Sekunden hängen).
/// Für Aktionen, die danach ein Ergebnis zeigen (Bestätigung, Papierkorb); Ansichten nutzen `FileStatCache`.
public enum FileExistence {
    public static func existing(_ paths: [String],
                                statter: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) async -> [String] {
        await Task.detached(priority: .userInitiated) { paths.filter(statter) }.value
    }
}
