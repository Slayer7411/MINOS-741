import Foundation
import Testing
@testable import MixCore

private final class OffMainFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var onMain: Int { lock.withLock { n } }
    func hit() { if Thread.isMainThread { lock.withLock { n += 1 } } }
}

/// Die Prüfung läuft nie auf dem Hauptthread, das Ergebnis bleibt das gleiche wie beim direkten Prüfen
@Test func existenceCheckRunsOffMainThread() async {
    let flag = OffMainFlag()
    let kept = await FileExistence.existing(["/m/a.mp3", "/m/b.mp3", "/m/c.mp3"]) { p in
        flag.hit()
        return p != "/m/b.mp3"
    }
    #expect(kept == ["/m/a.mp3", "/m/c.mp3"])
    #expect(flag.onMain == 0)
}

@Test func existenceCheckOfNothingReturnsNothing() async {
    #expect(await FileExistence.existing([]) { _ in true }.isEmpty)
}
