import Foundation
import Testing
@testable import MixApp
import MixCore

/// Ordner und freier Name der Aufnahme (läuft im Hintergrund): legt den Ordner an, überspringt belegte Namen
@Test func recordingStemSkipsTakenNamesAndCreatesFolder() throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("setrec-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: folder) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let base = RecordingName.stem(now)
    #expect(!fm.fileExists(atPath: folder.path))

    #expect(try SetRecorder.freeStem(folder, now, ext: "wav") == base)
    #expect(fm.fileExists(atPath: folder.path))

    fm.createFile(atPath: folder.appendingPathComponent("\(base).wav").path, contents: Data())
    #expect(try SetRecorder.freeStem(folder, now, ext: "wav") == "\(base) 2")
}
