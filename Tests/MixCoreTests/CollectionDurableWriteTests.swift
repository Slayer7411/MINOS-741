import Foundation
import Testing
@testable import MixCore

// Schreiben der Collection: Sperre, Änderung von außen, Reihenfolge der Platten-Synchronisation (nur temporäre Ordner)

private func nml(_ n: Int) -> String {
    var s = #"<?xml version="1.0" encoding="UTF-8" standalone="no" ?><NML VERSION="19"><COLLECTION ENTRIES="\#(n)">"#
    for i in 0..<n {
        s += #"<ENTRY TITLE="Track \#(i)" ARTIST="Test"><LOCATION DIR="/:music/:" FILE="t\#(i).wav" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"/></ENTRY>"#
    }
    s += "</COLLECTION></NML>"
    return s
}

private func durableRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("durable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Schlüssel des Tracks `i` (Datei t<i>.wav) im Index
private func key(_ index: NMLEntryIndex, _ i: Int) -> String {
    index.raw.keys.first { $0.hasSuffix(":t\(i).wav") }!
}

private func titles(_ url: URL) throws -> [String: String] {
    let tracks = try NMLParser.parse(data: Data(contentsOf: url)).tracks
    return Dictionary(tracks.map { ($0.key, $0.title) }, uniquingKeysWith: { a, _ in a })
}

private final class ErrorBox: @unchecked Sendable {
    var errors: [String] = []
    let lock = NSLock()
    func add(_ e: Error) { lock.lock(); errors.append("\(e)"); lock.unlock() }
}

@Test func concurrentWritersKeepBothChanges() throws {
    let root = try durableRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("collection.nml")
    try Data(nml(4).utf8).write(to: url)
    let index = NMLEntryIndex(nmlText: nml(4))
    let a = key(index, 0), b = key(index, 3)
    let box = ErrorBox()
    let group = DispatchGroup()
    for (k, title) in [(a, "Eins"), (b, "Zwei")] {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try CollectionWriter.write(url: url, job: CollectionWriter.Job(changes: [k: [.title: title]]),
                                               index: index, backupDir: nil)
            } catch { box.add(error) }
        }
    }
    group.wait()
    #expect(box.errors.isEmpty, "\(box.errors)")
    let t = try titles(url)
    #expect(t[a] == "Eins")
    #expect(t[b] == "Zwei")
}

@Test func changedOnDiskIsReappliedNotOverwritten() throws {
    let root = try durableRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("collection.nml")
    try Data(nml(3).utf8).write(to: url)
    let index = NMLEntryIndex(nmlText: nml(3))
    let a = key(index, 0)
    // andere Software speichert zwischen Lesen und Ersetzen (Größe ändert sich, damit die Prüfung greift)
    let other = nml(3).replacingOccurrences(of: "Track 2", with: "Fremd gespeichert")
    var job = CollectionWriter.Job(changes: [a: [.title: "Meine"]])
    job.expected = FileStamp(url: url)
    #expect(throws: CollectionWriter.Refusal.changedOnDisk) {
        try CollectionWriter.writeLocked(url: url, job: job, index: index, backupDir: nil,
                                         beforeReplace: { try! Data(other.utf8).write(to: url) })
    }
    #expect(try Data(contentsOf: url) == Data(other.utf8))
    // neu einlesen und die Änderung erneut anwenden: beide Stände stehen drin
    let index2 = NMLEntryIndex(nmlText: other)
    _ = try CollectionWriter.write(url: url, job: CollectionWriter.Job(changes: [a: [.title: "Meine"]]),
                                   index: index2, backupDir: nil)
    let t = try titles(url)
    #expect(t[a] == "Meine")
    #expect(t.values.contains("Fremd gespeichert"))
}

@Test func lockTimeoutFailsWithClearError() throws {
    let root = try durableRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("collection.nml")
    try Data(nml(1).utf8).write(to: url)
    try CollectionWriter.withLock(url) {
        var got: Error?
        let t0 = Date()
        do { try CollectionWriter.withLock(url, timeout: 0.2) {} } catch { got = error }
        #expect(Date().timeIntervalSince(t0) < 2)
        if case .locked(_)? = got as? CollectionWriter.Failure {} else { Issue.record("erwartet .locked, war \(String(describing: got))") }
    }
    // nach dem Freigeben wieder frei
    try CollectionWriter.withLock(url, timeout: 0.2) {}
}

@Test func replaceSyncsDataBeforeRenameAndDirectoryAfter() throws {
    let root = try durableRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("collection.nml")
    try Data("alt".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    var steps: [String] = []
    try CollectionWriter.replaceAtomically(url, with: Data("neu".utf8), trace: { steps.append($0) })
    #expect(try Data(contentsOf: url) == Data("neu".utf8))
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["collection.nml"])
    guard let w = steps.firstIndex(of: "write"), let c = steps.firstIndex(of: "close"),
          let r = steps.firstIndex(of: "rename"), let d = steps.firstIndex(of: "dirsync") else {
        Issue.record("Schritte fehlen: \(steps)")
        return
    }
    #expect(w < c && c < r && r < d, "\(steps)")
    // Platten-Synchronisation (F_FULLFSYNC, Fallback fsync) liegt vor dem close
    #expect(steps.contains("fullfsync") || steps.contains("fsync"))
    #expect((steps.firstIndex(of: "fullfsync") ?? steps.firstIndex(of: "fsync") ?? Int.max) < c, "\(steps)")
}
