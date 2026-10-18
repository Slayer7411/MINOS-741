import Foundation
import Testing
@testable import MixCore

/// WAV (8 kHz, mono, 16 bit, Stille) mit genauen Namens-Bytes (POSIX, ohne Unicode-Umwandlung durch Foundation)
private func writeWAV(_ path: String, seconds: Double) {
    let frames = Int(8000 * seconds)
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 2)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 2))
    d.append(Data(count: frames * 2))
    writeRaw(path, d)
}

private func writeRaw(_ path: String, _ data: Data) {
    let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    close(fd)
}

private func entry(_ dir: String, _ file: String, artist: String, title: String, bpm: Double = 128, playtime: Double = 10,
                   anchorMs: Double? = 100, key: Int? = 5, loudness: Bool = true) -> String {
    let nmlDir = dir.split(separator: "/").map { "/:" + $0 }.joined() + "/:"
    var s = "<ENTRY ARTIST=\"\(artist)\" TITLE=\"\(title)\"><LOCATION DIR=\"\(nmlDir)\" FILE=\"\(file)\" VOLUME=\"HD\"></LOCATION>"
    s += "<INFO PLAYTIME=\"\(Int(playtime))\" PLAYTIME_FLOAT=\"\(playtime)\"></INFO>"
    s += "<TEMPO BPM=\"\(bpm)\"></TEMPO>"
    if loudness { s += "<LOUDNESS PEAK_DB=\"-1\" PERCEIVED_DB=\"-3\"></LOUDNESS>" }
    if let key { s += "<MUSICAL_KEY VALUE=\"\(key)\"></MUSICAL_KEY>" }
    if let anchorMs { s += "<CUE_V2 NAME=\"AutoGrid\" TYPE=\"4\" START=\"\(anchorMs)\" LEN=\"0\" HOTCUE=\"-1\"></CUE_V2>" }
    return s + "</ENTRY>\n"
}

/// Temp-Ordner mit Dateien + kleine NML: jede Prüfung trifft genau ihren Fall, gute Tracks bleiben OK
@Test func consistencyCheckFindsEachCase() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("minos-check-\(UUID().uuidString)").path
    try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { chmod(root + "/Locked - Perm.wav", 0o644); try? fm.removeItem(atPath: root) }

    writeWAV(root + "/Good Artist - Good Title.wav", seconds: 10)
    writeWAV(root + "/Case Artist - Case Title.wav", seconds: 10)
    writeWAV(root + "/Cafe\u{301} - Cre\u{300}me.wav", seconds: 10)            // NFD auf der Platte
    writeWAV(root + "/Long - Track.wav", seconds: 10)                          // Collection sagt 30 s
    writeWAV(root + "/Twin A - Same.wav", seconds: 10)
    writeWAV(root + "/Twin B - Same.wav", seconds: 10)
    writeWAV(root + "/xyz123.wav", seconds: 10)                                // Name passt nicht
    writeWAV(root + "/Fast - Bpm.wav", seconds: 10)
    writeWAV(root + "/Raw - Unanalysed.wav", seconds: 10)
    writeWAV(root + "/Late - Anchor.wav", seconds: 10)
    writeWAV(root + "/Locked - Perm.wav", seconds: 10)
    writeRaw(root + "/Zero - Size.mp3", Data())
    writeRaw(root + "/Bad - Audio.wav", Data(String(repeating: "not audio at all ", count: 200).utf8))
    writeRaw(root + "/Loose - File.mp3", Data())                               // nicht in der Collection
    chmod(root + "/Locked - Perm.wav", 0o000)

    var nml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><NML VERSION=\"19\"><COLLECTION ENTRIES=\"16\">\n"
    nml += entry(root, "Good Artist - Good Title.wav", artist: "Good Artist", title: "Good Title (Original Mix)")
    nml += entry(root, "Gone - Missing.wav", artist: "Gone", title: "Missing")
    nml += entry(root, "Zero - Size.mp3", artist: "Zero", title: "Size")
    nml += entry(root, "Bad - Audio.wav", artist: "Bad", title: "Audio")
    nml += entry(root, "Long - Track.wav", artist: "Long", title: "Track", playtime: 30)
    nml += entry(root, "case artist - case title.wav", artist: "Case Artist", title: "Case Title")
    nml += entry(root, "Caf\u{E9} - Cr\u{E8}me.wav", artist: "Café", title: "Crème")   // NFC in der NML
    nml += entry(root, "xyz123.wav", artist: "Someone", title: "Something")
    nml += entry(root, "Twin A - Same.wav", artist: "Twin", title: "Same")
    nml += entry(root, "Twin B - Same.wav", artist: "Twin", title: "Same")
    nml += entry(root, "Fast - Bpm.wav", artist: "Fast", title: "Bpm", bpm: 250)
    nml += entry(root, "Raw - Unanalysed.wav", artist: "Raw", title: "Unanalysed", bpm: 0, anchorMs: nil, key: nil, loudness: false)
    nml += entry(root, "Late - Anchor.wav", artist: "Late", title: "Anchor", anchorMs: 20_000)
    nml += entry(root, "Locked - Perm.wav", artist: "Locked", title: "Perm")
    // gleiche Datei ein zweites Mal (andere Schreibweise im Schlüssel)
    nml += entry(root, "Good Artist - Good Title.wav", artist: "Good Artist", title: "Good Title (Original Mix)").replacingOccurrences(of: "VOLUME=\"HD\"", with: "VOLUME=\"HD2\"")
    nml += "</COLLECTION><PLAYLISTS><NODE TYPE=\"FOLDER\" NAME=\"$ROOT\"><SUBNODES COUNT=\"1\">"
    nml += "<NODE TYPE=\"PLAYLIST\" NAME=\"Set\"><PLAYLIST ENTRIES=\"2\" TYPE=\"LIST\">"
    nml += "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"HD/:gone/:ghost.mp3\"></PRIMARYKEY></ENTRY>"
    let goodKey = "HD" + root.split(separator: "/").map { "/:" + $0 }.joined() + "/:Good Artist - Good Title.wav"
    nml += "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"\(goodKey)\"></PRIMARYKEY></ENTRY>"
    nml += "</PLAYLIST></NODE></SUBNODES></NODE></PLAYLISTS></NML>"

    let c = try NMLParser.parse(data: Data(nml.utf8))
    #expect(c.tracks.count == 15)
    var input = ConsistencyCheck.Input(tracks: c.tracks, lists: ConsistencyCheck.lists(in: c.root), musicRoots: [root])
    input.concurrency = 4
    let run = ConsistencyRun.start(input)
    run.wait()
    let s = run.snapshot(sinceLine: 0, sinceFinding: 0)
    #expect(s.finished && !s.cancelled)
    #expect(s.done == 15)
    let f = run.allFindings
    func cats(_ file: String) -> Set<ConsistencyCheck.Category> {
        Set(f.filter { ($0.path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping == file.precomposedStringWithCanonicalMapping }.map(\.category))
    }
    #expect(cats("Gone - Missing.wav") == [.missing])
    #expect(cats("Zero - Size.mp3") == [.empty])
    #expect(cats("Bad - Audio.wav") == [.badAudio])
    #expect(cats("Long - Track.wav") == [.duration])
    #expect(cats("case artist - case title.wav") == [.pathCase])
    #expect(cats("Café - Crème.wav") == [.unicodeForm])
    #expect(cats("xyz123.wav") == [.name])
    #expect(cats("Twin B - Same.wav") == [.dupTrack])
    #expect(cats("Fast - Bpm.wav") == [.grid])
    #expect(cats("Raw - Unanalysed.wav") == [.noAnalysis])
    #expect(cats("Late - Anchor.wav") == [.grid])
    #expect(cats("Locked - Perm.wav") == [.unreadable])
    #expect(cats("Good Artist - Good Title.wav") == [.dupPath])          // nur der zweite Eintrag
    #expect(f.filter { $0.category == .dupPath }.count == 1)
    #expect(cats("ghost.mp3") == [.dangling])
    #expect(f.first { $0.category == .dangling }?.detail == "playlist: Set")
    #expect(cats("Loose - File.mp3") == [.notInCollection])
    #expect(f.filter { $0.category == .notInCollection }.count == 1)
    #expect(s.ok == 2)   // Good (erster Eintrag), Twin A
    #expect(s.counts[.missing] == 1 && s.counts[.pathCase] == 1 && s.counts[.unicodeForm] == 1)
    #expect(s.lines.contains { $0.category == nil && $0.path.hasSuffix("Twin A - Same.wav") })

    // Berichte
    let sum = ConsistencyCheck.Summary(source: "test.nml", tracks: 15, checked: s.done, ok: s.ok, counts: s.counts,
                                       folderFiles: s.folderFiles, elapsed: s.elapsed, cancelled: false)
    let text = ConsistencyCheck.reportText(sum, findings: f)
    #expect(text.contains("MISS  1") && text.contains("Gone - Missing.wav"))
    let csv = ConsistencyCheck.reportCSV(findings: f)
    #expect(csv.split(separator: "\n").count == f.count + 1)
    #expect(csv.contains("\"missing\";\"MISS\""))
}

/// Abbrechen: sofort beendet, Befunde bis dahin bleiben, nach dem Abbruch kommt nichts mehr dazu
@Test func consistencyCheckCancelsQuickly() throws {
    // klein und mit einem Arbeiter: der Test läuft parallel zu Zeit-Tests der Engine und soll keine Kerne belegen
    let tracks = (0..<20_000).map { i in
        var t = Track(key: "HD/:none/:\(i).mp3", path: "/nonexistent-minos/\(i).mp3")
        t.title = "T\(i)"; t.artist = "A"
        return t
    }
    var input = ConsistencyCheck.Input(tracks: tracks)
    input.concurrency = 1
    let run = ConsistencyRun.start(input)
    while run.snapshot(sinceLine: .max, sinceFinding: .max).done < 50 { usleep(200) }
    let t0 = Date()
    run.cancel()
    let s = run.snapshot(sinceLine: 0, sinceFinding: 0)
    #expect(Date().timeIntervalSince(t0) < 1.0)   // Abbruch kehrt ohne Warten zurück (Wanduhr unter Last: 1 s)
    #expect(s.finished && s.cancelled)
    run.wait()
    let after = run.snapshot(sinceLine: 0, sinceFinding: 0)
    #expect(after.done == s.done)
    #expect(after.done < tracks.count)
    #expect(run.allFindings.count == s.counts.values.reduce(0, +))
}

/// Name gegen Dateiname: Klammerzusätze, mehrere Artists, Akzente
@Test func nameHeuristic() {
    func t(_ file: String, _ artist: String, _ title: String) -> Track {
        var x = Track(key: file, path: "/m/" + file); x.artist = artist; x.title = title; return x
    }
    #expect(ConsistencyCheck.nameMismatch(t("01 Artist - Title.mp3", "Artist", "Title (Extended Mix)")) == nil)
    #expect(ConsistencyCheck.nameMismatch(t("Dj X & Other - Song.mp3", "Other & DJ X", "Other Song")) == nil)
    #expect(ConsistencyCheck.nameMismatch(t("Beyonce - Halo.mp3", "Beyoncé", "Unknown")) == nil)
    #expect(ConsistencyCheck.nameMismatch(t("track01.mp3", "Artist", "Title")) != nil)
    #expect(ConsistencyCheck.nameMismatch(t("Artistic - Titles.mp3", "Artist", "Title")) != nil)   // ganze Wörter
    #expect(ConsistencyCheck.nameMismatch(t("x.mp3", "", "")) == nil)
    #expect(ConsistencyCheck.nameMismatch(t("01.passworld.mp3", "Joseph Capriati", "Passworld - Original Mix")) == nil)
    #expect(ConsistencyCheck.nameMismatch(t("03 Bam Bam.m4a", "Matador", "BamBam")) == nil)
    #expect(ConsistencyCheck.nameMismatch(t("b1 - Stay Tuned.mp3", "Level Two", "2. Stay Tuned")) == nil)
    #expect(ConsistencyCheck.nameMismatch(t("01-i_dont_eat-mindtrip.mp3", "Ung & Bastos", "I don't eat")) == nil)
    #expect(ConsistencyCheck.nameMismatch(t("04 Matador - Mano.mp3", "Matador (IE)", "Nano")) == nil)
    #expect(ConsistencyCheck.nameMismatch(t("01 Ibiza 2008.mp3", "DJ G", "Ibiza 2007")) != nil)
    #expect(ConsistencyCheck.missingAnalysis(Track(key: "k", path: "/p")) == "no bpm · grid · key · loudness")
}
