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
