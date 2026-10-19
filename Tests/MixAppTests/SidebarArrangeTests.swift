import Foundation
import Testing
import MixCore
@testable import MixApp

// Seitenleiste: Überlagerung (Reihenfolge, Farben) in den Einstellungen; alte Einstellungen ohne den Schlüssel laden weiter

@MainActor @Test func prefsWithoutSidebarKeyDecodeWithDefault() throws {
    let old = #"{"ui": {"zoom": 1.25, "hidePlayedTracks": true}}"#
    let p = AppPrefs.decode(Data(old.utf8))
    #expect(p.ui.sidebar == SidebarArrange())
    #expect(p.ui.zoom == 1.25 && p.ui.hidePlayedTracks)
}

@MainActor @Test func prefsSidebarRoundTrip() throws {
    var p = AppPrefs.decode(Data(#"{"ui": {"zoom": 1.1}}"#.utf8))
    p.ui.sidebar.move("cu:B", to: "cu:A", in: "c:", ids: ["cu:A", "cu:B"])
    p.ui.sidebar.setMark(.green, for: "mf:/Users/x/Musik")
    let again = AppPrefs.decode(try JSONEncoder().encode(p))
    #expect(again.ui.sidebar == p.ui.sidebar)
    #expect(again.ui.sidebar.mark("mf:/Users/x/Musik") == .green)
    #expect(again.ui.zoom == 1.1)
}

@MainActor @Test func sidebarDragPayloadRoundTrip() {
    let s = SidebarDrag.prefix + "m:/Users/x" + "\n" + "mf:/Users/x/Musik/Techno"
    let item = SidebarDrag.item(s)
    #expect(item?.group == "m:/Users/x")
    #expect(item?.key == "mf:/Users/x/Musik/Techno")
    // Track- und Baum-Züge sind keine Umordnen-Züge
    #expect(SidebarDrag.item(TrackDrag.prefix + "abc") == nil)
    #expect(SidebarDrag.item(TreeDrag.prefix + UUID().uuidString) == nil)
    #expect(SidebarDrag.item(SidebarDrag.prefix + "ohne Zeilenumbruch") == nil)
}

@MainActor @Test func folderKeysAreStableAndSeparateFromCollectionKeys() {
    #expect(SidebarKey.folder("/Musik") == "mf:/Musik")
    #expect(SidebarKey.folderPath(SidebarKey.folder("/Musik/Techno")) == "/Musik/Techno")
    #expect(SidebarKey.folderGroup(nil) == "m:")
    #expect(SidebarKey.folderGroup("/Musik") == "m:/Musik")
    #expect(SidebarKey.collectionGroup("") == "c:")
}
