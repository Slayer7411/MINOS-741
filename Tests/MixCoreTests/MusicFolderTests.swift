import Foundation
import Testing
@testable import MixCore

/// Musik-Ordner auf einem Temp-Verzeichnis: Liste, Rekursion, Zuordnung zur Collection, lose Dateien
@Test func listsMusicFolder() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("minos-folders-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    for d in ["B Sub", "a sub", "a sub/deep", ".hidden"] {
        try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    for f in ["Artist X - Track 10.mp3", "Track 2.FLAC", "notes.txt", "cover.jpg", ".hidden/x.mp3",
              "a sub/Café.m4a", "a sub/deep/Deep - One.wav", "B Sub/b.aiff"] {
        try Data().write(to: root.appendingPathComponent(f))
    }
    let dir = root.path

    let l = MusicFolder.list(dir)
    #expect(l.folders.map { ($0 as NSString).lastPathComponent } == ["a sub", "B Sub"])
    #expect(l.files.map { ($0.path as NSString).lastPathComponent } == ["Artist X - Track 10.mp3", "Track 2.FLAC"])
    let deep = MusicFolder.list(dir, recursive: true)
    #expect(deep.files.count == 5)
    #expect(!deep.files.contains { $0.path.contains(".hidden") })

    // lose Datei: Titel aus dem Dateinamen, Schlüssel im NML-Format
    let loose = l.files[0].loose
    #expect(loose.loose && loose.artist == "Artist X" && loose.title == "Track 10")
    #expect(loose.bpm == 0 && loose.fileExists)
    let (vol, mount) = MusicFolder.volumeInfo(dir)
    #expect(loose.key == MusicFolder.nmlKey(l.files[0].path, volume: vol, mount: mount))
    #expect(MusicFolder.nmlKey("/Users/x/a.mp3", volume: "Macintosh HD", mount: "/") == "Macintosh HD/:Users/:x/:a.mp3")
    #expect(MusicFolder.nmlKey("/Volumes/Stick/Music/a.mp3", volume: "Stick", mount: "/Volumes/Stick") == "Stick/:Music/:a.mp3")

    // Collection-Zuordnung über den Pfad: Groß/klein und Unicode-Form (NFD im Dateisystem, NFC in der NML) egal
    var inColl = Track(key: "HD/:x/:cafe", path: (dir + "/A SUB/Café.m4a").precomposedStringWithCanonicalMapping)
    inColl.bpm = 128
    let index = MusicFolder.pathIndex([inColl])
    let sub = MusicFolder.list(dir + "/a sub")
    let nfd = sub.files[0].path.decomposedStringWithCanonicalMapping
    #expect(index[MusicFolder.match(nfd)] == "HD/:x/:cafe")
    #expect(index[sub.files[0].match] == "HD/:x/:cafe")
    #expect(index[l.files[0].match] == nil)
}

/// Standard-Ordner: tiefster Ordner mit 90 % der Dateien, Ausreißer zählen nicht
@Test func defaultMusicRoot() {
    var paths = (0..<95).map { "/Users/x/Drive/Music/Lib/\($0 % 3 == 0 ? "A" : "B")/t\($0).mp3" }
    paths += (0..<5).map { "/Users/x/Downloads/d\($0).mp3" }
    #expect(MusicFolder.defaultRoot(paths: paths) == "/Users/x/Drive/Music/Lib")
    #expect(MusicFolder.defaultRoot(paths: ["/a/b/c.mp3"]) == "/a/b")
    #expect(MusicFolder.defaultRoot(paths: []) == nil)
}

/// 2000 Dateien: lesen und zuordnen bleiben schnell (Index einmal gebaut)
@Test func listsLargeFolderQuickly() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("minos-folders-big-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for i in 0..<2000 { fm.createFile(atPath: root.appendingPathComponent("Artist \(i) - Title \(i).mp3").path, contents: nil) }
    let tracks = (0..<14000).map { Track(key: "k\($0)", path: root.path + "/Artist \($0) - Title \($0).mp3") }
    let index = MusicFolder.pathIndex(tracks)
    let t0 = Date()
    let l = MusicFolder.list(root.path)
    let hits = l.files.filter { index[$0.match] != nil }.count
    #expect(l.files.count == 2000 && hits == 2000)
    #expect(Date().timeIntervalSince(t0) < 5.0)   // 14000 Pfade, 2000 Dateien: Obergrenze gegen Quadratik, nicht gegen Last
}
