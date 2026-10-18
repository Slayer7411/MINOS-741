import AppKit
import ObjectiveC
import Testing
import MixCore
@testable import MixApp

// Band der Vorschau „ganze Zeile“: Breite = sichtbare Breite der Tabelle (scrollt mit) oder ganze Zeile

@MainActor @Test func previewBandSpanRowIgnoresVisibleRect() {
    let row = NSRect(x: 0, y: 0, width: 1000, height: 40), visible = NSRect(x: 300, y: 0, width: 400, height: 300)
    // ganze Zeile: wie bisher, 2 pt Luft links und rechts, untere Hälfte
    #expect(PreviewRow.band(in: row, visible: visible, span: .row) == NSRect(x: 2, y: 20, width: 996, height: 18))
    #expect(PreviewRow.band(in: row, visible: visible, span: .row, top: 10) == NSRect(x: 2, y: 10, width: 996, height: 28))
}

@MainActor @Test func previewBandSpanVisibleClipsToVisibleRect() {
    let visible = NSRect(x: 300, y: 0, width: 400, height: 300)
    // Zeile breiter als der Ausschnitt: Band nur über den sichtbaren Teil (300…700), 2 pt Luft
    let wide = NSRect(x: 0, y: 0, width: 1000, height: 40)
    #expect(PreviewRow.band(in: wide, visible: visible, span: .visible) == NSRect(x: 302, y: 20, width: 396, height: 18))
    // Zeile ganz im Ausschnitt: unverändert
    let inside = NSRect(x: 400, y: 40, width: 200, height: 40)
    #expect(PreviewRow.band(in: inside, visible: visible, span: .visible) == NSRect(x: 402, y: 60, width: 196, height: 18))
    // Zeile rechts neben dem Ausschnitt (ausgescrollt): keine Breite
    let away = NSRect(x: 800, y: 0, width: 1000, height: 40)
    #expect(PreviewRow.band(in: away, visible: visible, span: .visible).width == 0)
    // Zeile nur links angeschnitten: das Band beginnt am Rand des Ausschnitts
    let cut = NSRect(x: 200, y: 0, width: 300, height: 40)
    #expect(PreviewRow.band(in: cut, visible: visible, span: .visible) == NSRect(x: 302, y: 20, width: 196, height: 18))
}

@MainActor @Test func previewBandSpanDefaultsToVisible() {
    #expect(UIPrefs().previewBandSpan == .visible)
    // gespeicherte Einstellungen ohne das Feld: Standard „sichtbare Breite“, gespeicherte Werte bleiben
    #expect(AppPrefs.decode(Data(#"{"ui": {"zoom": 1.25}}"#.utf8)).ui.previewBandSpan == .visible)
    #expect(AppPrefs.decode(Data(#"{"ui": {"previewBandSpan": "Ganze Zeile"}}"#.utf8)).ui.previewBandSpan == .row)
}

@Test @MainActor func waveZoomSteps() {
    #expect(WaveZoomButtons.next(4, zoomIn: true) == 3 && WaveZoomButtons.next(4, zoomIn: false) == 6)
    #expect(WaveZoomButtons.next(5, zoomIn: true) == 4 && WaveZoomButtons.next(5, zoomIn: false) == 6)
    #expect(WaveZoomButtons.next(1, zoomIn: true) == 1 && WaveZoomButtons.next(16, zoomIn: false) == 16)
}

/// Header-Zelle überlebt das bitweise Kopieren durch AppKit (Marke und Schrift in NSCell-Eigenschaften)
@Test @MainActor func headerCellSurvivesCopies() {
    var cells: [TrackHeaderCell] = []
    let c = TrackHeaderCell(textCell: "Artist")
    c.sortMark = "▼2"
    c.font11 = TableStyle.mono(13)
    for _ in 0..<200 { autoreleasepool { cells.append(c.copy() as! TrackHeaderCell) } }
    cells.removeAll()
    for _ in 0..<200 { autoreleasepool { _ = c.copy() } }
    #expect(c.sortMark == "▼2" && c.font11.pointSize == 13)
    let k = c.copy() as! TrackHeaderCell
    #expect(k.sortMark == "▼2" && k.font11.pointSize == 13)
    c.sortMark = ""
    #expect(c.sortMark.isEmpty && k.sortMark == "▼2")
}

/// AppKit kopiert NSCell bitweise: eine Swift-Eigenschaft der Unterklasse hätte keine eigene Freigabe (Absturz in drawInterior).
/// Die Unterklasse darf deshalb keine gespeicherten Eigenschaften haben
@Test @MainActor func headerCellAddsNoStoredProperties() {
    #expect(class_getInstanceSize(TrackHeaderCell.self) == class_getInstanceSize(NSTableHeaderCell.self))
}

/// Absturzpfad: Kopie der Header-Zelle (Spalte wird gezogen), Quelle wird freigegeben, Kopie wird gezeichnet
@Test @MainActor func headerCellCopyDrawsAfterSourceIsGone() {
    var src: TrackHeaderCell? = TrackHeaderCell(textCell: "Artist")
    src?.sortMark = "▼2"
    src?.font11 = TableStyle.mono(13)
    let k = src!.copy() as! TrackHeaderCell
    src = nil
    let img = NSImage(size: NSSize(width: 200, height: 20))
    for _ in 0..<50 {
        img.lockFocus()
        k.draw(withFrame: NSRect(x: 0, y: 0, width: 200, height: 20), in: NSView())
        img.unlockFocus()
    }
    #expect(k.sortMark == "▼2" && k.font11.pointSize == 13)
}
