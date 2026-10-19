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

@Test func sidebarMoveInsertsBeforeTargetAndStoresWholeLevel() {
    var a = SidebarArrange()
    let ids = ["a", "b", "c", "d"]
    a.move("d", before: "b", in: "m:", ids: ids)
    #expect(a.sorted("m:", ids) == ["a", "d", "b", "c"])
    #expect(a.order["m:"] == ["a", "d", "b", "c"])

    // ans Ende, wenn kein Ziel
    a.move("a", before: nil, in: "m:", ids: ids)
    #expect(a.sorted("m:", ids) == ["d", "b", "c", "a"])

    // Ziel unbekannt: ans Ende
    a.move("b", before: "zz", in: "m:", ids: ids)
    #expect(a.sorted("m:", ids).last == "b")
}

@Test func sidebarMoveIgnoresNoOpAndForeignIds() {
    var a = SidebarArrange()
    let ids = ["a", "b"]
    a.move("a", before: "a", in: "m:", ids: ids)
    #expect(a.order.isEmpty)
    a.move("x", before: "a", in: "m:", ids: ids)   // nicht in der Ebene
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
    a.move("b", before: "a", in: "c:", ids: ["a", "b"])
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
    a.moveSection(.playlists, before: .collection)
    #expect(a.sectionOrder() == [.playlists, .collection, .folders, .explorer])
    // ans Ende ohne Ziel
    a.moveSection(.playlists, before: nil)
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])
    // Abschnitt vor sich selbst: keine Änderung der Reihenfolge
    a.moveSection(.explorer, before: .explorer)
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])

    a.moveSection(.explorer, before: .collection)
    a.resetSectionOrder()
    #expect(a.sectionOrder() == [.collection, .folders, .explorer, .playlists])
    // andere Ebenen und Farben bleiben
    #expect(a.order["m:"] == ["mf:/Musik"])
    #expect(a.mark("mf:/Musik") == .blue)
}

@Test func sidebarSectionOrderRoundTrip() throws {
    var a = SidebarArrange()
    a.moveSection(.explorer, before: .folders)
    let data = try JSONEncoder().encode(a)
    let b = try JSONDecoder().decode(SidebarArrange.self, from: data)
    #expect(b == a)
    #expect(b.sectionOrder() == [.collection, .explorer, .folders, .playlists])
}
