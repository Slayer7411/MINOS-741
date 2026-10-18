import Foundation
import Testing
@testable import MixCore

/// Playlists der Collection per UUID schreiben: neue Reihenfolge, ENTRIES, Sicherung, Ablehnung bei doppelten UUIDs,
/// Smartlists und doppelten Einträgen, Prüfung, dass nur der eine Knoten sich ändert. Geschrieben wird nur eine Kopie
/// im Temp-Ordner.

private let pA = "Macintosh HD/:Music/:a.mp3"
private let pB = "Macintosh HD/:Music/:b.mp3"
private let pC = "Macintosh HD/:Music/:c.mp3"
private let uZiel = "11111111111111111111111111111111"
private let uRegel = "22222222222222222222222222222222"
private let uFremd = "33333333333333333333333333333333"
private let uDoppelt = "44444444444444444444444444444444"

private func entry(_ file: String) -> String {
    "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"Macintosh HD/:Music/:\(file)\"></PRIMARYKEY>\n</ENTRY>\n"
}

private func track(_ file: String) -> String {
    "<ENTRY MODIFIED_DATE=\"2024/7/30\" MODIFIED_TIME=\"1\" TITLE=\"\(file)\" ARTIST=\"X\"><LOCATION DIR=\"/:Music/:\" FILE=\"\(file)\" VOLUME=\"Macintosh HD\" VOLUMEID=\"Macintosh HD\"></LOCATION>\n</ENTRY>\n"
}

/// drei Tracks; „Ziel“ (eine Playlist, leer bis auf b), „Regel“ (Smartlist), „Fremd“ (a, b, c), zwei Playlists mit
/// derselben UUID („Doppelt“)
private let playlistNML = """
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<NML VERSION="19"><HEAD COMPANY="www.example.com" PROGRAM="x"></HEAD>
<COLLECTION ENTRIES="3">
\(track("a.mp3"))\(track("b.mp3"))\(track("c.mp3"))</COLLECTION>
<PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="5">
<NODE TYPE="PLAYLIST" NAME="Ziel"><PLAYLIST ENTRIES="1" TYPE="LIST" UUID="\(uZiel)">\(entry("b.mp3"))</PLAYLIST></NODE>
<NODE TYPE="SMARTLIST" NAME="Regel"><SMARTLIST UUID="\(uRegel)"><SEARCH_EXPRESSION QUERY="$COMMENT % &quot;x&quot;"></SEARCH_EXPRESSION></SMARTLIST></NODE>
<NODE TYPE="PLAYLIST" NAME="Fremd"><PLAYLIST ENTRIES="3" TYPE="LIST" UUID="\(uFremd)">\(entry("a.mp3"))\(entry("b.mp3"))\(entry("c.mp3"))</PLAYLIST></NODE>
<NODE TYPE="PLAYLIST" NAME="Doppelt"><PLAYLIST ENTRIES="0" TYPE="LIST" UUID="\(uDoppelt)"></PLAYLIST></NODE>
<NODE TYPE="PLAYLIST" NAME="Doppelt 2"><PLAYLIST ENTRIES="0" TYPE="LIST" UUID="\(uDoppelt)"></PLAYLIST></NODE>
</SUBNODES></NODE></PLAYLISTS></NML>

"""

/// Kopie im Temp-Ordner: (Datei, Sicherungsordner)
private func playlistTempCopy(_ text: String) throws -> (URL, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-plwrite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("collection.nml")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return (url, dir.appendingPathComponent("Backup MINOS-741"))
}

private func node(_ name: String, in c: Collection) -> PlaylistNode? { c.root.first { $0.name == name } }

@Test func addsTrackToPlaylistByUUIDKeepsOtherNodesAndWritesBackup() throws {
    let (url, backups) = try playlistTempCopy(playlistNML)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let before = try NMLParser.parse(url: url)
    var job = CollectionWriter.Job()
    job.playlistEdits = [.init(uuid: uZiel, keys: [pB, pA])]
    let r = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: playlistNML), backupDir: backups)
    #expect(r.playlistsEdited == [uZiel])
    #expect(r.changed)
    #expect(r.backup.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    let after = try NMLParser.parse(url: url)
    #expect(node("Ziel", in: after)?.trackKeys == [pB, pA])
    #expect(node("Ziel", in: after)?.uuid == uZiel)
    #expect(node("Fremd", in: after)?.trackKeys == node("Fremd", in: before)?.trackKeys)
    #expect(node("Regel", in: after)?.query == node("Regel", in: before)?.query)
    #expect(after.tracks.count == 3)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("<PLAYLIST ENTRIES=\"2\" TYPE=\"LIST\" UUID=\"\(uZiel)\">"))
}

@Test func reordersPlaylistKeepingEntryTextAndCount() throws {
    let (url, _) = try playlistTempCopy(playlistNML)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var job = CollectionWriter.Job()
    job.playlistEdits = [.init(uuid: uFremd, keys: [pC, pA, pB])]
    let r = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: playlistNML), backupDir: nil)
    #expect(r.playlistsEdited == [uFremd])
    let after = try NMLParser.parse(url: url)
    #expect(node("Fremd", in: after)?.trackKeys == [pC, pA, pB])
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("<PLAYLIST ENTRIES=\"3\" TYPE=\"LIST\" UUID=\"\(uFremd)\">"))
    // Eintrag-Text bleibt Zeichen für Zeichen
    #expect(text.contains(entry("c.mp3") + entry("a.mp3") + entry("b.mp3")))
}

@Test func refusesDuplicatesUnlessAllowedAndLeavesFileAlone() throws {
    let (url, _) = try playlistTempCopy(playlistNML)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var job = CollectionWriter.Job()
    job.playlistEdits = [.init(uuid: uZiel, keys: [pB, pB])]
    var refused = false
    do { _ = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: playlistNML), backupDir: nil) } catch { refused = true }
    #expect(refused)
    #expect(try String(contentsOf: url, encoding: .utf8) == playlistNML)
    job.playlistEdits = [.init(uuid: uZiel, keys: [pB, pB], allowDuplicates: true)]
    let r = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: playlistNML), backupDir: nil)
    #expect(r.changed)
    #expect(node("Ziel", in: try NMLParser.parse(url: url))?.trackKeys == [pB, pB])
}

@Test func refusesUnknownTrackUUIDSmartlistAndSharedUUID() throws {
    let cases: [CollectionWriter.PlaylistEdit] = [
        .init(uuid: uZiel, keys: [pB, "Macintosh HD/:Music/:fehlt.mp3"]),   // Schlüssel nicht in der Collection
        .init(uuid: "99999999999999999999999999999999", keys: [pA]),          // UUID nicht in der Datei
        .init(uuid: uRegel, keys: [pA]),                                       // Smartlist, keine Liste
        .init(uuid: uDoppelt, keys: [pA]),                                     // UUID zweimal in der Datei
    ]
    for edit in cases {
        let (url, _) = try playlistTempCopy(playlistNML)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var job = CollectionWriter.Job()
        job.playlistEdits = [edit]
        var refused = false
        do { _ = try CollectionWriter.write(url: url, job: job, index: NMLEntryIndex(nmlText: playlistNML), backupDir: nil) } catch { refused = true }
        #expect(refused, "angenommen: \(edit.uuid)")
        #expect(try String(contentsOf: url, encoding: .utf8) == playlistNML)
    }
}

@Test func validationRefusesChangesOutsideTheEditedPlaylist() throws {
    let old = try NMLParser.parse(data: Data(playlistNML.utf8)).root
    let zielOnly = playlistNML.replacingOccurrences(of: entry("b.mp3") + "</PLAYLIST></NODE>\n<NODE TYPE=\"SMARTLIST\"",
                                                    with: entry("a.mp3") + "</PLAYLIST></NODE>\n<NODE TYPE=\"SMARTLIST\"")
    let good = try NMLParser.parse(data: Data(zielOnly.utf8)).root
    // der eine Knoten ist geändert, alles andere gleich: ok
    try CollectionWriter.validatePlaylists(old: old, new: good, edits: [.init(uuid: uZiel, keys: [pA])])
    // dieselbe Datei, aber die Liste „Fremd“ hat sich auch verändert: abgelehnt
    let fremdChanged = zielOnly.replacingOccurrences(of: entry("c.mp3") + "</PLAYLIST>", with: "</PLAYLIST>")
    let bad = try NMLParser.parse(data: Data(fremdChanged.utf8)).root
    var refused = false
    do { try CollectionWriter.validatePlaylists(old: old, new: bad, edits: [.init(uuid: uZiel, keys: [pA])]) } catch { refused = true }
    #expect(refused)
}

@Test func ordering_helpersInsertWithoutDuplicatesAndMove() {
    #expect(CollectionPlaylists.inserting([pB, pC], into: [pA, pB], at: 0) == [pC, pA, pB])
    #expect(CollectionPlaylists.inserting([pC], into: [pA, pB], at: 9) == [pA, pB, pC])
    #expect(CollectionPlaylists.inserting([pB], into: [pA, pB], at: 0, allowDuplicates: true) == [pB, pA, pB])
    #expect(CollectionPlaylists.moving([pC], in: [pA, pB, pC], to: 0) == [pC, pA, pB])
    #expect(CollectionPlaylists.moving([pA], in: [pA, pB, pC], to: 3) == [pB, pC, pA])
    #expect(CollectionPlaylists.moving([pB], in: [pA, pB, pC], to: 0) == [pB, pA, pC])
    #expect(CollectionPlaylists.moving([pX], in: [pA, pB], to: 0) == [pA, pB])
}

private let pX = "Macintosh HD/:Music/:x.mp3"
