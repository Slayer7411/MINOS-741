import Foundation
import Testing
@testable import MixCore

/// kleine Collection mit Umlauten, Entities, fehlendem ALBUM und einem gesperrten Track
let editNML = """
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<NML VERSION="19"><HEAD COMPANY="www.example.com" PROGRAM="x"></HEAD>
<COLLECTION ENTRIES="3"><ENTRY MODIFIED_DATE="2024/7/30" MODIFIED_TIME="64041" LOCK="0" AUDIO_ID="AIJe///c7t7==" TITLE="Bär &amp; Wolf" ARTIST="Ünal"><LOCATION DIR="/:Music/:" FILE="a &amp; b.m4a" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"></LOCATION>
<MODIFICATION_INFO AUTHOR_TYPE="user"></MODIFICATION_INFO>
<INFO BITRATE="614001" GENRE="Techno" LABEL="Ostgut Ton" COMMENT="1-4 groove &quot;start&quot; " RATING="K tief · B sub » BASIS" KEY="11m" PLAYTIME="131" RANKING="153" IMPORT_DATE="2024/2/11" RELEASE_DATE="2011/9/26" FLAGS="12" FILESIZE="9884"></INFO>
<TEMPO BPM="130.000473" BPM_QUALITY="100.000000"></TEMPO>
<MUSICAL_KEY VALUE="19"></MUSICAL_KEY>
<CUE_V2 NAME="AutoGrid" DISPL_ORDER="0" TYPE="4" START="43.963768" LEN="0.000000" REPEATS="-1" HOTCUE="0"></CUE_V2>
</ENTRY>
<ENTRY MODIFIED_DATE="2025/5/30" MODIFIED_TIME="46086" TITLE="Orlok's Symphony" ARTIST="Größe"><LOCATION DIR="/:Music/:" FILE="b.mp3" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"></LOCATION>
<ALBUM OF_TRACKS="11" TRACK="6" TITLE="Vantage Point"></ALBUM>
<INFO GENRE="Dub" COMMENT="2-2 dub"></INFO>
<TEMPO BPM="124.000000" BPM_QUALITY="100.000000"></TEMPO>
</ENTRY>
<ENTRY LOCK="1" TITLE="Locked" ARTIST="X"><LOCATION DIR="/:Music/:" FILE="c.mp3" VOLUME="Macintosh HD" VOLUMEID="Macintosh HD"></LOCATION>
<INFO COMMENT="fix"></INFO>
<TEMPO BPM="128.000000" BPM_QUALITY="100.000000"></TEMPO>
</ENTRY>
</COLLECTION>
<PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="1">
<NODE TYPE="PLAYLIST" NAME="Prep &amp; Co"><PLAYLIST ENTRIES="1" TYPE="LIST"><ENTRY><PRIMARYKEY TYPE="TRACK" KEY="Macintosh HD/:Music/:b.mp3"></PRIMARYKEY></ENTRY></PLAYLIST></NODE>
</SUBNODES></NODE></PLAYLISTS></NML>

"""

private let keyA = "Macintosh HD/:Music/:a & b.m4a"
private let keyB = "Macintosh HD/:Music/:b.mp3"
private let keyC = "Macintosh HD/:Music/:c.mp3"

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("minos-edit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Bytes vor und nach einem Block müssen gleich bleiben
private func outside(_ text: String, block: String) -> (String, String) {
    let r = text.range(of: block, options: .literal)!
    return (String(text[..<r.lowerBound]), String(text[r.upperBound...]))
}

@Test func fieldNormalizeAndValues() {
    #expect(TrackField.releaseDate.normalize("2011/9/26") == "2011-09-26")
    #expect(TrackField.releaseDate.normalize("2011") == "2011-01-01")
    #expect(TrackField.releaseDate.normalize("26.9.") == nil)
    #expect(TrackField.rating.normalize("6") == nil)
    #expect(TrackField.rating.normalize("") == "0")
    #expect(TrackField.bpm.normalize("128,5") == "128.500")
    #expect(TrackField.bpm.normalize("") == nil)
    #expect(TrackField.trackNumber.normalize("0") == "")
    #expect(TrackField.comment.normalize("a\nb") == "a b")
    var t = Track(key: "k", path: "/k")
    TrackField.releaseDate.set("2011-09-26", on: &t)
    #expect(TrackField.releaseDate.value(of: t) == "2011-09-26")
    TrackField.rating.set("4", on: &t)
    #expect(t.rating == 4)
    t.locked = true
    #expect(!TrackField.bpm.isEditable(t) && TrackField.title.isEditable(t))
}

/// Zurückschreiben: geänderte Attribute ändern sich, alles andere bleibt Byte für Byte gleich
@Test func writeBackKeepsEverythingElse() throws {
    let index = NMLEntryIndex(nmlText: editNML)
    let oldA = try #require(index.raw[keyA]), oldB = try #require(index.raw[keyB]), oldC = try #require(index.raw[keyC])
    let changesA: [TrackField: String] = [
        .title: "Bär & Wölfe <live>", .artist: "Ünal", .comment2: "", .album: "Ä \"EP\"", .trackNumber: "3",
        .rating: "5", .releaseDate: "2012-01-02", .bpm: "131.250", .mix: "Original Mix", .remixer: "Größe",
    ]
    let newA = CollectionWriter.patch(entry: oldA, changes: changesA)
    #expect(newA.contains(#"TITLE="Bär &amp; Wölfe &lt;live&gt;" ARTIST="Ünal">"#))
    #expect(!newA.contains("RATING="))                                  // leerer Kommentar 2 -> Attribut weg
    #expect(newA.contains(#"COMMENT="1-4 groove &quot;start&quot; ""#))  // unverändert, Escaping bleibt
    #expect(newA.contains("RANKING=\"255\"") && newA.contains("RELEASE_DATE=\"2012/1/2\""))
    #expect(newA.contains("<TEMPO BPM=\"131.250000\" BPM_QUALITY=\"100.000000\"></TEMPO>"))
    #expect(newA.contains("</LOCATION>\n<ALBUM TITLE=\"Ä &quot;EP&quot;\" TRACK=\"3\"></ALBUM>\n<MODIFICATION_INFO"))
    #expect(newA.contains(#"MIX="Original Mix""#) && newA.contains(#"REMIXER="Größe""#))
    #expect(newA.contains("AUDIO_ID=\"AIJe///c7t7==\"") && newA.contains("<CUE_V2 NAME=\"AutoGrid\""))
    // gleiche Werte -> Block unverändert
    #expect(CollectionWriter.patch(entry: oldB, changes: [.title: "Orlok's Symphony", .trackNumber: "6", .rating: "0"]) == oldB)
    let newB = CollectionWriter.patch(entry: oldB, changes: [.title: "Orlok's Symphony (Edit)", .genre: "Dub & Bass"])
    #expect(newB.contains(#"TITLE="Orlok's Symphony (Edit)""#) && newB.contains(#"GENRE="Dub &amp; Bass""#))

    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("collection.nml")
    try Data(editNML.utf8).write(to: url)
    let backups = dir.appendingPathComponent("Backup MINOS-741")
    let now = Date(timeIntervalSince1970: 1_791_000_000)
    let res = try CollectionWriter.write(url: url, changes: [keyA: changesA, keyB: [.genre: "Dub & Bass"]], index: index,
                                         backupDir: backups, now: now)
    #expect(res.changed && res.missing.isEmpty && res.written.count == 2)
    let text = try String(contentsOf: url, encoding: .utf8)
    // Sicherung = alter Stand, Byte für Byte
    let b = try #require(res.backup)
    #expect(b.lastPathComponent.hasPrefix("collection_") && b.deletingLastPathComponent().lastPathComponent == "Backup MINOS-741")
    #expect(try Data(contentsOf: b) == Data(editNML.utf8))
    // außerhalb der geänderten Blöcke alles gleich, unveränderter Block identisch
    let blockB = try #require(res.blocks[keyB])
    let (pre, post) = outside(editNML, block: oldA)
    let (pre2, _) = outside(text, block: res.blocks[keyA]!)
    #expect(pre == pre2)
    #expect(text.contains(oldC))
    #expect(post.replacingOccurrences(of: oldB, with: blockB) == String(text[text.range(of: res.blocks[keyA]!, options: .literal)!.upperBound...]))
    // neu lesen
    let c = try NMLParser.parse(url: url)
    #expect(c.tracks.count == 3)
    let a = try #require(c.tracks.first { $0.key == keyA })
    #expect(a.title == "Bär & Wölfe <live>" && a.artist == "Ünal" && a.comment2.isEmpty && a.album == "Ä \"EP\"")
    #expect(a.trackNumber == 3 && a.rating == 5 && Track.dateText(a.releaseDate) == "2012-01-02" && abs(a.bpm - 131.25) < 1e-6)
    #expect(a.mix == "Original Mix" && a.remixer == "Größe" && a.comment == "1-4 groove \"start\" " && a.label == "Ostgut Ton")
    #expect(a.cues.count == 1 && a.musicalKey == 19)
    #expect(c.tracks.first { $0.key == keyB }?.genre == "Dub & Bass")
    #expect(c.tracks.first { $0.key == keyC }?.locked == true)
    #expect(c.root.children.first?.name == "Prep & Co")

    // zweiter Lauf mit altem Index: Block nicht mehr da -> gemeldet, Datei unverändert; jede Änderung bekommt eine Sicherung
    let res2 = try CollectionWriter.write(url: url, changes: [keyA: [.title: "Nochmal"]], index: index, backupDir: backups,
                                          now: now.addingTimeInterval(600))
    #expect(res2.missing == [keyA] && !res2.changed)
    #expect(try String(contentsOf: url, encoding: .utf8) == text)
    var idx = index
    idx.update(res.blocks)
    let res3 = try CollectionWriter.write(url: url, changes: [keyA: [.title: "Nochmal"]], index: idx, backupDir: backups,
                                          now: now.addingTimeInterval(1200))
    #expect(res3.changed && res3.backup != nil)
    #expect(try NMLParser.parse(url: url).tracks.first { $0.key == keyA }?.title == "Nochmal")
    let res4 = try CollectionWriter.write(url: url, changes: [keyB: [.title: "Später"]], index: idx, backupDir: backups,
                                          now: now.addingTimeInterval(3700))
    #expect(res4.backup != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 3)
    // keine Temp-Dateien liegen geblieben
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Backup MINOS-741", "collection.nml"])
}

/// Windows-Zeilenenden bleiben, neue Elemente bekommen dieselben
@Test func writeBackKeepsCRLF() {
    let block = "<ENTRY TITLE=\"T\" ARTIST=\"A\"><LOCATION DIR=\"/:M/:\" FILE=\"x.mp3\" VOLUME=\"V\"></LOCATION>\r\n<INFO COMMENT=\"c\"></INFO>\r\n</ENTRY>"
    let new = CollectionWriter.patch(entry: block, changes: [.album: "Alb", .bpm: "120.000", .comment: "c"])
    #expect(new == "<ENTRY TITLE=\"T\" ARTIST=\"A\"><LOCATION DIR=\"/:M/:\" FILE=\"x.mp3\" VOLUME=\"V\"></LOCATION>\r\n<ALBUM TITLE=\"Alb\"></ALBUM>\r\n<INFO COMMENT=\"c\"></INFO>\r\n<TEMPO BPM=\"120.000000\"></TEMPO>\r\n</ENTRY>")
}

/// Metadaten-Änderungen: speichern, neu laden, über den Track legen (Suchtext inklusive)
@Test func metadataStoreRoundTrip() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("metadata.json")
    let c = try NMLParser.parse(data: Data(editNML.utf8))
    let base = Dictionary(uniqueKeysWithValues: c.tracks.map { ($0.key, $0) })
    let store = MetadataStore(url: url)
    store.merge([keyA: [.title: "Neu ä", .genre: "Techno", .rating: "2"], keyC: [.bpm: "140.000", .comment: "x"]], base: base)
    store.flush()
    #expect(store.edit(for: keyA)?.values == [.title: "Neu ä", .rating: "2"])   // Genre = Collection-Wert -> fällt heraus
    let back = MetadataStore(url: url)
    #expect(back.all == store.all)
    let a = back.edit(for: keyA)!.apply(to: base[keyA]!)
    #expect(a.title == "Neu ä" && a.rating == 2)
    #expect(a.matches(words: [Track.fold("NEU A")]))
    let locked = back.edit(for: keyC)!.apply(to: base[keyC]!)
    #expect(locked.bpm == 128 && locked.comment == "x")                       // gesperrt: BPM bleibt
    back.clear(written: [keyA: [.title: "Neu ä", .rating: "3"]])
    #expect(back.edit(for: keyA)?.values == [.rating: "2"])
    back.remove([keyA, keyC])
    back.flush()
    #expect(MetadataStore(url: url).all.isEmpty)
}

/// Zurückschreiben auf einer Kopie der echten Collection (die echte Datei wird nur gelesen): außerhalb der
/// geänderten Blöcke Byte für Byte gleich, gleiche Anzahl Tracks – läuft nur mit vorhandener Collection
@Test func writeBackOnRealCopy() throws {
    let real = realCollection()
    guard FileManager.default.fileExists(atPath: real.path) else { return }
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("collection.nml")
    try FileManager.default.copyItem(at: real, to: url)
    let original = try Data(contentsOf: url)
    let text = try #require(String(data: original, encoding: .utf8))
    let index = NMLEntryIndex(nmlText: text)
    let keys = Array(index.raw.keys.sorted().prefix(3))
    var changes: [String: [TrackField: String]] = [:]
    for k in keys { changes[k] = [.title: "MINOS & Test ä", .comment2: "edit » BASIS", .rating: "4", .album: "Rel"] }
    let res = try CollectionWriter.write(url: url, changes: changes, index: index, backupDir: nil)
    #expect(res.changed && res.missing.isEmpty)
    var expected = text
    for k in keys { expected = expected.replacingOccurrences(of: index.raw[k]!, with: res.blocks[k]!) }
    #expect(try Data(contentsOf: url) == Data(expected.utf8))
    let c = try NMLParser.parse(url: url)
    #expect(c.tracks.count == (try NMLParser.parse(data: original)).tracks.count)
    for k in keys {
        let t = try #require(c.tracks.first { $0.key == k })
        #expect(t.title == "MINOS & Test ä" && t.comment2 == "edit » BASIS" && t.rating == 4 && t.album == "Rel")
    }
}
