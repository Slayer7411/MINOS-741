import Foundation
import Testing
@testable import MixCore

// Überlagerung der Seitenleiste: Reihenfolge und Farbe liegen in den Einstellungen, nie in der Collection-Datei

@Test func sidebarOrderAppliesSavedOrderThenNewThenDropsRemoved() {
    var a = SidebarArrange()
    // gespeichert: c, a, gone (gone ist nicht mehr da)
    a.order["m:"] = ["c", "a", "gone"]
    // natürlich: a, b, c, d (b und d sind neu)
    #expect(a.sorted("m:", ["a", "b", "c", "d"]) == ["c", "a", "b", "d"])
    // ohne gespeicherte Ebene: natürliche Reihenfolge
    #expect(a.sorted("other", ["x", "y"]) == ["x", "y"])
}

@Test func sidebarMoveUpInsertsBeforeTargetAndStoresWholeLevel() {
    var a = SidebarArrange()
    let ids = ["a", "b", "c", "d"]
    a.move("d", to: "b", in: "m:", ids: ids)   // nach oben: davor
    #expect(a.sorted("m:", ids) == ["a", "d", "b", "c"])
    #expect(a.order["m:"] == ["a", "d", "b", "c"])

    // ans Ende, wenn kein Ziel
    a.move("a", to: nil, in: "m:", ids: ids)
    #expect(a.sorted("m:", ids) == ["d", "b", "c", "a"])

    // Ziel unbekannt: ans Ende
    a.move("b", to: "zz", in: "m:", ids: ids)
    #expect(a.sorted("m:", ids).last == "b")
}

@Test func sidebarMoveDownInsertsAfterTarget() {
    var a = SidebarArrange()
    let ids = ["a", "b", "c", "d"]
    a.move("a", to: "c", in: "m:", ids: ids)   // nach unten: dahinter
    #expect(a.sorted("m:", ids) == ["b", "c", "a", "d"])
}

@Test func sidebarMoveReachesFirstAndLastPositions() {
    var a = SidebarArrange()
    let ids = ["a", "b", "c", "d"]
    // erster ans Ende (Ziel = letzter, nach unten)
    a.move("a", to: "d", in: "m:", ids: ids)
    #expect(a.sorted("m:", ids) == ["b", "c", "d", "a"])
    // letzter nach ganz oben (Ziel = erster, nach oben)
    a.move("a", to: "b", in: "m:", ids: ids)
    #expect(a.sorted("m:", ids) == ["a", "b", "c", "d"])
}

@Test func sidebarMoveNeighbourSwapsBothDirections() {
    var a = SidebarArrange()
    let ids = ["a", "b", "c", "d"]
    a.move("a", to: "b", in: "m:", ids: ids)   // a nach unten, hinter b
    #expect(a.sorted("m:", ids) == ["b", "a", "c", "d"])
    a.move("a", to: "b", in: "m:", ids: ids)   // a nach oben, vor b: zurück
    #expect(a.sorted("m:", ids) == ["a", "b", "c", "d"])
}

@Test func sidebarMoveIgnoresNoOpAndForeignIds() {
    var a = SidebarArrange()
    let ids = ["a", "b"]
    a.move("a", to: "a", in: "m:", ids: ids)
    #expect(a.order.isEmpty)
    a.move("x", to: "a", in: "m:", ids: ids)   // nicht in der Ebene
    #expect(a.order.isEmpty)
}

@Test func sidebarMarkLookupAndClear() {
    var a = SidebarArrange()
    #expect(a.mark("mf:/Musik") == nil)
    a.setMark(.red, for: "mf:/Musik")
    a.setMark(.grey, for: "cu:1234")
    #expect(a.mark("mf:/Musik") == .red)
    #expect(a.mark("cu:1234") == .grey)
    a.setMark(nil, for: "mf:/Musik")
    #expect(a.mark("mf:/Musik") == nil)
    #expect(a.marks.count == 1)
}

@Test func sidebarArrangeRoundTripAndOldDataDecodes() throws {
    var a = SidebarArrange()
    a.move("b", to: "a", in: "c:", ids: ["a", "b"])
    a.setMark(.purple, for: "o:ABC")
    let data = try JSONEncoder().encode(a)
    #expect(try JSONDecoder().decode(SidebarArrange.self, from: data) == a)

    // leer und ohne Schlüssel: Standard
    #expect(try JSONDecoder().decode(SidebarArrange.self, from: Data("{}".utf8)) == SidebarArrange())

    // unbekannte Farbe fällt weg, der Rest bleibt
    let odd = #"{"order": {"m:": ["x"]}, "marks": {"o:1": "pink", "o:2": "blue"}}"#
    let b = try JSONDecoder().decode(SidebarArrange.self, from: Data(odd.utf8))
    #expect(b.order["m:"] == ["x"])
    #expect(b.marks == ["o:2": .blue])
}

@Test func sidebarSectionOrderNaturalWithoutSavedKey() {
    #expect(SidebarArrange().sectionOrder() == [.collection, .folders, .explorer, .playlists])
    // alte Einstellungen mit anderen Ebenen, aber ohne „root“: natürliche Reihenfolge
    let old = #"{"order": {"m:": ["x"], "c:": ["cu:1"]}}"#
    let a = try! JSONDecoder().decode(SidebarArrange.self, from: Data(old.utf8))
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])
}

@Test func sidebarSectionOrderSavedFirstNewAfterRemovedIgnored() {
    var a = SidebarArrange()
    // gespeichert: playlists, ein entfernter Abschnitt, collection; folders und explorer sind neu (natürlich danach)
    a.order[SidebarArrange.sectionGroup] = ["playlists", "gone", "collection"]
    #expect(a.sectionOrder() == [.playlists, .collection, .folders, .explorer])
    // nur ein Abschnitt gespeichert: die übrigen in natürlicher Reihenfolge dahinter
    a.order[SidebarArrange.sectionGroup] = ["folders"]
    #expect(a.sectionOrder() == [.folders, .collection, .explorer, .playlists])
    // alle Schlüssel unbekannt: natürliche Reihenfolge
    a.order[SidebarArrange.sectionGroup] = ["x", "y"]
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])
}

@Test func sidebarSectionMoveAndReset() {
    var a = SidebarArrange()
    a.setMark(.blue, for: "mf:/Musik")
    a.order["m:"] = ["mf:/Musik"]
    // nach oben: vor das Ziel
    a.moveSection(.playlists, to: .collection)
    #expect(a.sectionOrder() == [.playlists, .collection, .folders, .explorer])
    // ans Ende: letzter Abschnitt steht als Ziel, erster wird dahinter gesetzt
    a.moveSection(.playlists, to: nil)
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])
    // Abschnitt auf sich selbst: keine Änderung
    a.moveSection(.explorer, to: .explorer)
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])

    a.moveSection(.explorer, to: .collection)
    a.resetSectionOrder()
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])
    // andere Ebenen und Farben bleiben
    #expect(a.order["m:"] == ["mf:/Musik"])
    #expect(a.mark("mf:/Musik") == .blue)
}

@Test func sidebarFirstSectionReachesEndAndLastReachesTop() {
    var a = SidebarArrange()
    // erster nach unten an das Ende (Ziel = letzter Abschnitt)
    a.moveSection(.collection, to: .playlists)
    #expect(a.sectionOrder() == [.folders, .explorer, .playlists, .collection])
    // letzter ganz nach oben (Ziel = erster Abschnitt)
    a.moveSection(.collection, to: .folders)
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])
    a.moveSection(.playlists, to: .collection)
    #expect(a.sectionOrder() == [.playlists, .collection, .folders, .explorer])
}

@Test func sidebarSectionNeighbourSwapsBothDirections() {
    var a = SidebarArrange()
    a.moveSection(.collection, to: .folders)   // nach unten, hinter folders
    #expect(a.sectionOrder() == [.folders, .collection, .explorer, .playlists])
    a.moveSection(.collection, to: .folders)   // nach oben, vor folders: zurück
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])
}

@Test func sidebarSectionOrderRoundTrip() throws {
    var a = SidebarArrange()
    a.moveSection(.explorer, to: .folders)
    let data = try JSONEncoder().encode(a)
    let b = try JSONDecoder().decode(SidebarArrange.self, from: data)
    #expect(b == a)
    #expect(b.sectionOrder() == [.collection, .explorer, .folders, .playlists])
}
