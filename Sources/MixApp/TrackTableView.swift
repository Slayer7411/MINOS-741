import AppKit
import SwiftUI
import MixCore
import MixEngine

// Track-Liste auf NSTableView: Zeilen über den Index aus der Liste, neue Liste = reloadData (gebaut werden nur die
// sichtbaren Zeilen), feste Zeilenhöhe, eigene Zellen (zeichnen Text/Bild selbst, eine Ebene je Zeile).
// Vorher SwiftUI-Table: jeder große Listenwechsel verglich bzw. baute alle Zeilen neu, ~0,25 s Hauptthread.
// Zweizeilig: Sammelspalte „Track“ (Teile aus ⌘, -> BROWSER) zeichnet die Zeile genauso selbst; Lage der Teile aus
// `trackLayout` (Zeichnen, Klicks, Inline-Bearbeitung), eigene gespeicherte Anordnung `columns.<bereich>.2`.

/// Spalte der Track-Tabelle. `id` = Schlüssel in der gespeicherten Anordnung (`columns.<bereich>`), Breiten bei 100 %
struct TrackColumn {
    enum Kind { case played, cloud, analyzed, info, color, cover, artist, title, preview, field(TrackField), bpm, key, harmony, groove, time, gain, rating, comment2, plays, lastPlayed, importDate, bitrate, file, path, rip, track }
    let id: String
    let title: String
    let kind: Kind
    var width: CGFloat
    var min: CGFloat
    var max: CGFloat = .greatestFiniteMagnitude
    var hidden = false
    var sort: KeyPathComparator<Track>?
    /// Name im Spalten-Menü des Kopfes (Symbol-Spalten)
    var menuTitle: String?
    var fixed: Bool { min == max }

    static func fixed(_ id: String, _ title: String, _ kind: Kind, _ w: CGFloat, hidden: Bool = false, sort: KeyPathComparator<Track>? = nil, menu: String? = nil) -> TrackColumn {
        TrackColumn(id: id, title: title, kind: kind, width: w, min: w, max: w, hidden: hidden, sort: sort, menuTitle: menu)
    }
    static func flex(_ id: String, _ title: String, _ kind: Kind, min: CGFloat, ideal: CGFloat, max: CGFloat = .greatestFiniteMagnitude, hidden: Bool = false, sort: KeyPathComparator<Track>? = nil) -> TrackColumn {
        TrackColumn(id: id, title: title, kind: kind, width: ideal, min: min, max: max, hidden: hidden, sort: sort)
    }

    /// Standard-Reihenfolge und -Sichtbarkeit (wie die SwiftUI-Tabelle vorher)
    static let all: [TrackColumn] = [
        .fixed("played", "▶", .played, 16, menu: String(localized: "▶ Gespielt")),
        .fixed("info", "☁✓", .info, 28, sort: KeyPathComparator(\Track.analyzedSort), menu: String(localized: "☁✓ Info (Cloud, Analysiert)")),
        .fixed("cloud", "☁", .cloud, 16, hidden: true, menu: String(localized: "☁ Cloud")),
        .fixed("analyzed", "✓", .analyzed, 16, hidden: true, sort: KeyPathComparator(\Track.analyzedSort), menu: String(localized: "✓ Analysiert")),
        .fixed("color", "", .color, 6, sort: KeyPathComparator(\Track.color), menu: String(localized: "Farbe")),
        .flex("cover", "Cover", .cover, min: 22, ideal: 44, hidden: true),
        .flex("artist", "Artist", .artist, min: 80, ideal: 150, sort: KeyPathComparator(\Track.artist)),
        .flex("title", "Title", .title, min: 80, ideal: 200, sort: KeyPathComparator(\Track.title)),
        .flex("preview", "Preview", .preview, min: 60, ideal: 150, max: 400),
        .flex("remixer", "Remixer", .field(.remixer), min: 60, ideal: 110, hidden: true, sort: KeyPathComparator(\Track.remixer)),
        .flex("producer", "Producer", .field(.producer), min: 60, ideal: 110, hidden: true, sort: KeyPathComparator(\Track.producer)),
        .flex("release", "Release", .field(.album), min: 60, ideal: 130, hidden: true, sort: KeyPathComparator(\Track.album)),
        .fixed("trackno", "Track #", .field(.trackNumber), 40, hidden: true, sort: KeyPathComparator(\Track.trackNumber)),
        .fixed("bpm", "BPM", .bpm, 56, sort: KeyPathComparator(\Track.bpm)),
        .fixed("key", "Key", .key, 36, sort: KeyPathComparator(\Track.openKey)),
        .fixed("harmony", "Match", .harmony, 44, sort: KeyPathComparator(\Track.harmonySort), menu: String(localized: "Match (Harmonie, Tempo zum Master)")),
        .fixed("groove", "Tags ≈", .groove, 58, menu: String(localized: "Tags ≈ (Tag-Gruppen zum Master)")),
        .fixed("keytext", "Key Text", .field(.keyText), 40, hidden: true, sort: KeyPathComparator(\Track.keyText)),
        .fixed("time", "Time", .time, 44, sort: KeyPathComparator(\Track.duration)),
        .fixed("gain", "Gain", .gain, 42, hidden: true, sort: KeyPathComparator(\Track.gainSort)),
        .fixed("rating", "Rating", .rating, 56, hidden: true, sort: KeyPathComparator(\Track.rating)),
        .flex("comment", "Comment", .field(.comment), min: 80, ideal: 170, sort: KeyPathComparator(\Track.comment)),
        .flex("comment2", "Comment 2", .comment2, min: 80, ideal: 260, sort: KeyPathComparator(\Track.comment2)),
        .flex("label", "Label", .field(.label), min: 60, ideal: 110, sort: KeyPathComparator(\Track.label)),
        .flex("catalog", "Catalog No", .field(.catalogNo), min: 50, ideal: 90, hidden: true, sort: KeyPathComparator(\Track.catalogNo)),
        .flex("genre", "Genre", .field(.genre), min: 50, ideal: 100, hidden: true, sort: KeyPathComparator(\Track.genre)),
        .fixed("plays", "Plays", .plays, 38, sort: KeyPathComparator(\Track.playCount)),
        .fixed("lastplayed", "Last Played", .lastPlayed, 74, hidden: true, sort: KeyPathComparator(\Track.lastPlayedSort)),
        .fixed("import", "Import", .importDate, 74, sort: KeyPathComparator(\Track.importSort)),
        .fixed("releasedate", "Release Date", .field(.releaseDate), 74, hidden: true, sort: KeyPathComparator(\Track.releaseSort)),
        .fixed("bitrate", "Bitrate", .bitrate, 44, hidden: true, sort: KeyPathComparator(\Track.bitrate)),
        .flex("file", "File Name", .file, min: 80, ideal: 220, hidden: true, sort: KeyPathComparator(\Track.fileName)),
        .flex("path", "Path", .path, min: 120, ideal: 360, hidden: true, sort: KeyPathComparator(\Track.path)),
        .flex("mix", "Mix", .field(.mix), min: 60, ideal: 110, hidden: true, sort: KeyPathComparator(\Track.mix)),
        .fixed("rip", "Rip", .rip, 92, hidden: true, menu: String(localized: "Rip (Befund der Rip-Prüfung)")),
        // Sammelspalte, nur zweizeilig sichtbar (ersetzt die Spalten ihrer Teile)
        .flex("track", "Track", .track, min: 160, ideal: 420, hidden: true, sort: KeyPathComparator(\Track.title)),
    ]
    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

/// gespeicherte Spalten-Anordnung im Format der früheren SwiftUI-Tabelle (TableColumnCustomization als JSON):
/// `columnOrder` = IDs, `perColumnState` = abwechselnd ID und Zustand (Sichtbarkeit, Breite)
enum ColumnLayout {
    struct State: Equatable, Codable {
        var order: [String] = []
        var widths: [String: CGFloat] = [:]
        /// nur ausdrücklich gesetzte Sichtbarkeit (fehlt = Standard der Spalte)
        var hidden: [String: Bool] = [:]
    }

    private static func id(_ e: Any) -> String? {
        ((e as? [String: Any])?["base"] as? [String: Any]).flatMap { ($0["explicit"] as? [String: Any])?["_0"] as? String }
    }
    private static func ref(_ id: String) -> [String: Any] { ["base": ["explicit": ["_0": id]]] }

    static func decode(_ data: Data) -> State? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var s = State()
        s.order = (obj["columnOrder"] as? [Any] ?? []).compactMap(id)
        let per = obj["perColumnState"] as? [Any] ?? []
        for i in stride(from: 0, to: per.count - 1, by: 2) {
            guard let k = id(per[i]), let st = per[i + 1] as? [String: Any] else { continue }
            if let w = st["currentWidth"] as? Double { s.widths[k] = CGFloat(w) }
            if let v = st["visibility"] as? [String: Any] {
                if v["hidden"] != nil { s.hidden[k] = true } else if v["visible"] != nil { s.hidden[k] = false }
            }
        }
        return s
    }

    static func encode(_ s: State) -> Data {
        var per: [Any] = []
        for k in s.order {
            var st: [String: Any] = [:]
            if let w = s.widths[k] { st["currentWidth"] = Double(w) }
            st["visibility"] = s.hidden[k].map { $0 ? ["hidden": [String: Any]()] : ["visible": [String: Any]()] } ?? ["automatic": [String: Any]()]
            per.append(ref(k))
            per.append(st)
        }
        let obj: [String: Any] = ["columnOrder": s.order.map(ref), "perColumnState": per]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    /// neue Spalten an ihren Platz statt ans Ende: „played“ vorne, „cloud“ dahinter, „cover“ neben die Farbe,
    /// „preview“ hinter den Titel; übrige fehlende hinten
    static func placed(_ s: State) -> [String] {
        var order = s.order.filter { TrackColumn.byID[$0] != nil }
        guard !order.isEmpty else { return TrackColumn.all.map(\.id) }
        if !order.contains("played") { order.insert("played", at: 0) }
        // ☁ und ✓ sind seit 0.8 eine Spalte „info“: alte Anordnung -> info an der Stelle der ersten, die zweite fällt weg
        if !order.contains("info") {
            if let i = order.firstIndex(where: { $0 == "cloud" || $0 == "analyzed" }) {
                order[i] = "info"
                order.removeAll { $0 == "cloud" || $0 == "analyzed" }
            } else {
                order.insert("info", at: order.firstIndex(of: "played").map { $0 + 1 } ?? 0)
            }
        }
        if !order.contains("cover") { order.insert("cover", at: order.firstIndex(of: "color").map { $0 + 1 } ?? min(3, order.count)) }
        if !order.contains("preview") { order.insert("preview", at: order.firstIndex(of: "title").map { $0 + 1 } ?? order.count) }
        if !order.contains("harmony") { order.insert("harmony", at: order.firstIndex(of: "key").map { $0 + 1 } ?? order.count) }
        if !order.contains("groove") { order.insert("groove", at: order.firstIndex(of: "harmony").map { $0 + 1 } ?? order.count) }
        for c in TrackColumn.all where !order.contains(c.id) { order.append(c.id) }
        return order
    }

    /// Anordnung für zweizeilige Zeilen aus der einzeiligen: Sammelspalte an der Stelle der ersten ersetzten Spalte,
    /// so breit wie die sichtbaren ersetzten Spalten zusammen; ersetzte Spalten versteckt
    static func twoLine(from s: State, replacing parts: Set<String>) -> State {
        var order = placed(s).filter { $0 != "track" }
        let at = order.firstIndex { parts.contains($0) } ?? order.count
        order.insert("track", at: at)
        var out = State(order: order, widths: s.widths, hidden: s.hidden)
        let shown = parts.filter { id in !(s.hidden[id] ?? TrackColumn.byID[id]?.hidden ?? true) }
        let w = shown.reduce(CGFloat(0)) { $0 + (s.widths[$1] ?? TrackColumn.byID[$1]?.width ?? 0) }
        if w > 0 { out.widths["track"] = Swift.max(TrackColumn.byID["track"]?.min ?? 160, w) }
        for id in parts { out.hidden[id] = true }
        out.hidden["track"] = false
        return out
    }
}

/// Farben und Schriften der Tabelle (741: Void, Knochenweiß, Rot nur als Zustand, Lila = zweiter Zustand)
@MainActor
enum TableStyle {
    static let void = NSColor(Theme.void), chitin = NSColor(Theme.chitin), raised = NSColor(Theme.chitinRaised)
    static let bone = NSColor(Theme.bone), muted = NSColor(Theme.muted), hairline = NSColor(Theme.hairline)
    static let state = NSColor(Theme.state), secondary = NSColor(Theme.secondary), gold = NSColor(Theme.gold)
    /// Harmonie zum Master: gleich Lila, ±1 / Relativ hell, ±2 grau, unpassend gedimmt
    static let energy = bone.withAlphaComponent(0.62), clash = muted.withAlphaComponent(0.5)
    static func harmony(_ s: Harmony.Step) -> NSColor {
        switch s {
        case .same: secondary
        case .adjacent, .relative: bone
        case .energy: energy
        case .clash: clash
        }
    }
    /// Auswahl: rot getönt, auch ohne Fokus (dann schwächer), dazu ein voller Streifen links (`selectionStripe` pt)
    static let selected = state.withAlphaComponent(0.32), selectedDim = state.withAlphaComponent(0.20)
    static let selectionStripe: CGFloat = 2
    static let trackColors: [NSColor] = (0...7).map { NSColor(Theme.trackColor($0)) }

    /// Zeilenhöhe: einzeilig wie vorher (100 %: 24 pt), eigene Vorschau-Spalte 17 pt Bild + Rand, zweizeilig
    /// PreviewRow.rowHeight + 8 pt. Zweizeiliger Text (`twoText`): zwei Textzeilen + Luft, mit Band darunter (`textHeight`)
    static func rowHeight(_ ui: UIPrefs, twoText: Bool = false) -> CGFloat {
        let z = UIZoom.shared.factor, pad = CGFloat(ui.browserRowPadding)
        if twoText {
            let text = textHeight(ui)
            guard ui.previewMode == .fullRow else { return (text + max(3, pad * 0.6) * z).rounded() }
            return (text + bandHeight.z + max(2, pad - 5)).rounded()
        }
        switch ui.previewMode {
        case .fullRow: return PreviewRow.rowHeight(textSize: ui.previewTextSize).z + max(2, pad - 3)
        case .column: return max((13 * z + pad).rounded(), 17 * z + max(2, pad - 3))
        default: return (13 * z + pad).rounded()
        }
    }

    /// Abstand der zwei Textzeilen (Grundlinie zu Grundlinie) bei Schrift `size`
    static func lineStep(_ size: CGFloat) -> CGFloat { (size * 1.3).rounded() }
    /// Höhe des Textbereichs zweizeilig (zwei Zeilen + 3 pt Luft)
    static func textHeight(_ ui: UIPrefs) -> CGFloat { 2 * lineStep(TagChipsText.Metrics.of(ui).size) + 3.z }
    /// Band der Vorschau unter zwei Textzeilen (100 %)
    static let bandHeight: CGFloat = 11

    static func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "IBMPlexMono-SemiBold" : "IBMPlexMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    private static var attrCache: [String: [NSAttributedString.Key: Any]] = [:]
    static func attrs(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let k = "\(font.fontName)|\(font.pointSize)|\(color.hash)"
        if let a = attrCache[k] { return a }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        attrCache[k] = a
        return a
    }
}

/// Zeile: zeichnet alle Zellen selbst (CoreText, keine Unteransicht je Zelle – nur die Inline-Bearbeitung ist eine).
/// Auswahl knochenweiß gedämpft, Haarlinie unten, keine abwechselnden Hintergründe
final class TrackRowView: NSTableRowView, NSViewToolTipOwner {
    weak var owner: TrackTableController?
    /// Zellen mit Hinweis (☁, ✓): Lage der zuletzt angemeldeten Bereiche
    var tips: [NSRect] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let owner else { return }
        if owner.stripe(self) { LiveList.stripeFill.setFill(); bounds.fill() }
        guard owner.rowLines else { return }
        (owner.liveMode ? LiveList.separator : TableStyle.hairline.withAlphaComponent(0.45)).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Live: harte Umkehrung (knochenweiß, die Schrift in der Zeile wird dunkel gezeichnet)
        if owner?.liveMode == true { TableStyle.bone.setFill() } else { (isEmphasized ? TableStyle.selected : TableStyle.selectedDim).setFill() }
        bounds.fill()
        TableStyle.state.setFill()
        NSRect(x: 0, y: 0, width: TableStyle.selectionStripe, height: bounds.height).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        owner?.drawCells(self, dirtyRect)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        owner?.toolTip(self, at: point) ?? ""
    }
}

/// Spaltenkopf: Chitin, Plex Mono, Haarlinien, Sortierung als ▲/▼
final class TrackHeaderCell: NSTableHeaderCell {
    // keine eigenen Swift-Referenzen: AppKit kopiert Header-Zellen bitweise (NSCell), eine kopierte Swift-Eigenschaft
    // wurde doppelt freigegeben (Absturz in drawInterior). Ablage in Eigenschaften, die NSCell selbst richtig kopiert
    var sortMark: String {
        get { placeholderString ?? "" }
        set { placeholderString = newValue.isEmpty ? nil : newValue }
    }
    var font11: NSFont {
        get { font ?? TableStyle.mono(11) }
        set { font = newValue }
    }

    override func draw(withFrame f: NSRect, in v: NSView) {
        TableStyle.chitin.setFill()
        f.fill()
        TableStyle.hairline.setFill()
        NSRect(x: f.maxX - 1, y: f.minY + 5, width: 1, height: f.height - 10).fill()
        NSRect(x: f.minX, y: f.maxY - 1, width: f.width, height: 1).fill()
        drawInterior(withFrame: f, in: v)
    }

    override func drawInterior(withFrame f: NSRect, in v: NSView) {
        let font = stringValue == "☁" ? NSFont.systemFont(ofSize: font11.pointSize + 2) : font11
        let a = TableStyle.attrs(font, sortMark.isEmpty ? TableStyle.bone.withAlphaComponent(0.8) : TableStyle.bone)
        let h = ceil(font.ascender - font.descender)
        var r = NSRect(x: f.minX + 4, y: f.midY - h / 2, width: f.width - 8, height: h + 2)
        if !sortMark.isEmpty {
            let m = NSAttributedString(string: sortMark, attributes: TableStyle.attrs(TableStyle.mono(font11.pointSize * 0.8), TableStyle.muted))
            let w = m.size().width
            m.draw(at: NSPoint(x: f.maxX - w - 5, y: f.midY - m.size().height / 2))
            r.size.width -= w + 4
        }
        NSAttributedString(string: stringValue, attributes: a).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

final class TrackHeaderView: NSTableHeaderView {
    /// Doppelklick auf einen Spaltentrenner: Spalte auf den längsten Text (Index der Spalte)
    var onFitColumn: ((Int) -> Void)?

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2, let tv = tableView, let i = dividerColumn(at: convert(e.locationInWindow, from: nil), tv) {
            onFitColumn?(i)
            return
        }
        super.mouseDown(with: e)
    }

    /// Spalte, deren rechter Rand (± 4 pt) am Punkt liegt, nur verstellbare
    private func dividerColumn(at p: NSPoint, _ tv: NSTableView) -> Int? {
        for (i, c) in tv.tableColumns.enumerated() where !c.isHidden && c.resizingMask.contains(.userResizingMask) {
            if abs(p.x - headerRect(ofColumn: i).maxX) <= 4 { return i }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        TableStyle.chitin.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

/// Tabelle: Return = Inline-Bearbeitung (Rest wie NSTableView: Pfeile, ⇧/⌘-Auswahl, Tippen springt)
final class TrackNSTable: NSTableView {
    var onReturn: (() -> Void)?
    /// ⌫ / ⌦: aus eigener Playlist bzw. Preparation entfernen (false = nicht verbraucht)
    var onDelete: (() -> Bool)?
    /// Klick ins Vorschau-Bild des vorgehörten Tracks: Sprung statt Auswahl
    var onSeek: ((NSEvent) -> Bool)?

    override func mouseDown(with e: NSEvent) {
        if onSeek?(e) == true { return }
        super.mouseDown(with: e)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36 || e.keyCode == 76, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onReturn?()
            return
        }
        if e.keyCode == 51 || e.keyCode == 117, e.modifierFlags.intersection([.option, .control, .shift]).isEmpty, onDelete?() == true { return }
        super.keyDown(with: e)
    }
}

/// Menüeintrag mit Aktion als Closure
final class ActionItem: NSMenuItem {
    private var run: () -> Void = {}
    convenience init(_ title: String, key: String = "", _ run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        self.run = run
    }
    @objc private func fire() { run() }
}

/// Inline-Bearbeitung in der Zelle: Textfeld (Rahmen rot bei ungültiger Eingabe) oder fünf Sterne
final class InlineFieldCell: NSView, NSTextFieldDelegate {
    private let box = NSView()
    let field = NSTextField()
    var edit: InlineEdit?
    weak var model: BrowserPaneModel?
    var finish: ((InlineEdit, Bool) -> Void)?
    /// Zeile des Felds in der Zelle (oben = 0); nil = ganze Zelle
    var lineRect: CGRect?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = TableStyle.raised
        field.textColor = TableStyle.bone
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        box.wantsLayer = true
        box.layer?.backgroundColor = TableStyle.raised.cgColor
        box.layer?.borderWidth = 1
        box.addSubview(field)
        addSubview(box)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ e: InlineEdit, text: String, font: NSFont) {
        edit = e
        field.font = font
        field.stringValue = text
        updateBorder()
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.edit == e, let w = self.window, self.model?.inline == e else { return }
            w.makeFirstResponder(self.field)
        }
    }

    override func layout() {
        super.layout()
        let line = lineRect.map { NSRect(x: 0, y: $0.minY, width: bounds.width, height: $0.height) } ?? bounds
        let h = ceil((field.font?.ascender ?? 10) - (field.font?.descender ?? -3)) + 4
        box.frame = NSRect(x: 0, y: (line.midY - h / 2).rounded(), width: bounds.width, height: h)
        field.frame = box.bounds.insetBy(dx: 2.z, dy: 1)
    }

    private func updateBorder() {
        let bad = edit.map { $0.field.normalize(field.stringValue) == nil } ?? false
        box.layer?.borderColor = (bad ? TableStyle.state : TableStyle.bone.withAlphaComponent(0.6)).cgColor
    }

    func controlTextDidChange(_ n: Notification) {
        model?.inlineText = field.stringValue
        updateBorder()
    }

    /// Fokus weg (Klick daneben): übernehmen; Tab/Return/Esc erledigt vorher InlineEditController
    func controlTextDidEndEditing(_ n: Notification) {
        guard let edit, model?.inline == edit else { return }
        model?.inlineText = field.stringValue
        finish?(edit, true)
    }
}

final class StarsCell: NSView {
    var value = 0
    var font: NSFont = TableStyle.mono(13)
    var set: ((Int) -> Void)?
    var lineRect: CGRect?
    override var isFlipped: Bool { true }

    private var starWidth: CGFloat { NSAttributedString(string: "★", attributes: [.font: font]).size().width + 1.z }

    override func draw(_ dirtyRect: NSRect) {
        let s = String((1...5).map { $0 <= value ? "★" : "☆" })
        let a = TableStyle.attrs(font, TableStyle.bone)
        let line = lineRect ?? bounds
        var x: CGFloat = 0
        for ch in s {
            let t = NSAttributedString(string: String(ch), attributes: a)
            t.draw(at: NSPoint(x: x, y: line.midY - t.size().height / 2))
            x += starWidth
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let n = Swift.max(1, Swift.min(5, Int(p.x / starWidth) + 1))
        set?(n == value ? 0 : n)
    }
}

/// Zustand und Aktionen einer Track-Tabelle (Daten-Quelle, Delegate, Menüs). Der SwiftUI-Teil (`TrackTable`) reicht
/// Zeilen und Darstellung herein, die Tabelle selbst spiegelt nur.
@MainActor
final class TrackTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var model: BrowserPaneModel?
    weak var store: LibraryStore?
    weak var history: HistoryStore?
    weak var mix: MixModel? { didSet { observeHarmony() } }
    weak var inline: InlineEditController?
    /// nur Selbsttest-Bilder: feste Zeilen
    var fixedRows: [Track]?
    /// nach jedem Neuaufbau (Band der Vorschau „ganze Zeile“)
    var onReload: (() -> Void)?
    private(set) var table: TrackNSTable?
    private var scroll: NSScrollView?

    /// alles außer den Zeilen, was die sichtbaren Zellen bestimmt
    struct Look: Equatable {
        var ui: UIPrefs
        var zoom: CGFloat
        var filter: TagFilter
        var inline: InlineEdit?
        var played: Set<String>
        var cloud: Int
        var rip = 0
        var tick: Int
        /// vorgehörter Track (Strich in Vorschau-Spalte bzw. hinter dem Titel)
        var preview: String?
        /// Zeilen zweizeilig mit Sammelspalte (Bereich bzw. ⌘, -> BROWSER)
        var twoText = false
        /// Live-Lesbarkeit: feste Spalten (LiveList), Schrift und Zeilen nach den Einstellungen
        var liveList = false
    }

    private var rows: [Track] = []
    private var generation = -1
    private(set) var look: Look?
    private var shownSelection: Set<String> = []
    private var applying = false
    private var saveWork: DispatchWorkItem?
    private var font: NSFont = TableStyle.mono(11)
    /// Band der Vorschau „ganze Zeile“: Abstand vom oberen Zeilenrand (nil = kein Band)
    private(set) var bandTop: CGFloat?
    /// zweizeilig mit Sammelspalte „Track“
    private(set) var twoText = false
    /// Teile der Sammelspalte (⌘, -> BROWSER)
    private(set) var parts: [TrackPart] = TrackParts.standard
    private var shortValues = true
    /// Sammelspalte: Titel halbfett, Rest normal (gleiche Dickte in Plex Mono), Breite eines Zeichens
    private var boldFont: NSFont = TableStyle.mono(11, bold: true)
    private var plainFont: NSFont = TableStyle.mono(11)
    private var badgeFont: NSFont = TableStyle.mono(9, bold: true)
    private var advance: CGFloat = 6.6
    /// gewählter bzw. zuletzt angeklickter Track (Detailleiste)
    private(set) var detailKey: String?
    /// Trennlinie unter jeder Zeile (⌘, -> BROWSER)
    var rowLines = true
    /// Live-Lesbarkeit aktiv: feste Spalten (gespeicherte Anordnung bleibt unberührt), Schrift und Zeilen aus LiveList
    private(set) var liveMode = false
    /// Schrift für BPM und Key im Live-Modus (fett, eine Stufe größer); sonst wie `font`
    private var emphasisFont: NSFont = TableStyle.mono(11)
    /// Zeile gerade invertiert gezeichnet (Live-Modus, ausgewählt): Schrift dunkel
    private var inverted = false

    var shownRows: [Track] { rows }

    /// Zeile mit abwechselndem Hintergrund (Live-Modus, Einstellung)
    func stripe(_ rv: TrackRowView) -> Bool {
        guard liveMode, look?.ui.liveListStripes == true, let tv = table else { return false }
        return tv.row(for: rv) % 2 == 1
    }

    func makeView() -> NSScrollView {
        let tv = TrackNSTable()
        tv.style = .plain
        tv.headerView = TrackHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        tv.backgroundColor = TableStyle.void
        tv.usesAlternatingRowBackgroundColors = false
        tv.gridStyleMask = []
        tv.selectionHighlightStyle = .regular
        tv.allowsMultipleSelection = true
        tv.allowsEmptySelection = true
        tv.allowsColumnReordering = true
        tv.allowsColumnResizing = true
        tv.allowsTypeSelect = true
        tv.usesAutomaticRowHeights = false
        tv.rowSizeStyle = .custom
        tv.focusRingType = .none
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tv.intercellSpacing = NSSize(width: (10.z).rounded(), height: 0)
        tv.dataSource = self
        tv.delegate = self
        tv.target = self
        tv.doubleAction = #selector(doubleClicked)
        tv.onReturn = { [weak self] in self?.returnKey() }
        tv.onDelete = { [weak self] in self?.deleteKey() ?? false }
        // Tracks ziehen (Baum, Decks, Preparation); in eigenen Playlists auch innerhalb der Tabelle (Reihenfolge)
        tv.registerForDraggedTypes([.string, .fileURL])   // Finder-Dateien: in eigene Playlists (nur Collection-Tracks)
        tv.setDraggingSourceOperationMask(.copy, forLocal: false)
        tv.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        // Ziehen beginnt in jede Richtung (zu den Decks geht es nach oben); mehrere Zeilen über ⇧ / ⌘, nicht durch Aufziehen
        tv.verticalMotionCanBeginDrag = true
        tv.onSeek = { [weak self] e in self?.seekClick(e) ?? false }
        (tv.headerView as? TrackHeaderView)?.onFitColumn = { [weak self] i in self?.fitColumn(i) }
        let menu = NSMenu()
        menu.delegate = self
        tv.menu = menu
        let head = NSMenu()
        head.delegate = self
        tv.headerView?.menu = head
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        // Rollbalken als Overlay, nie im Layout: ein Balken, der Platz braucht, lässt die Spalten (automatische Breite)
        // neu verteilen, danach verschwindet er wieder – die Liste flimmert, bis jemand eine Spalte von Hand ändert
        sv.scrollerStyle = .overlay
        NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak sv] _ in
            MainActor.assumeIsolated { sv?.scrollerStyle = .overlay }
        }
        sv.drawsBackground = true
        sv.backgroundColor = TableStyle.void
        sv.borderType = .noBorder
        table = tv
        scroll = sv
        return sv
    }

    // MARK: Spalten

    /// Schlüssel der gespeicherten Anordnung: einzeilig `columns.<bereich>`, zweizeilig `columns.<bereich>.2`
    private var layoutKey: String? { model.flatMap { LiveList.storageKey(name: $0.name, twoText: twoText, live: liveMode) } }

    /// von der Sammelspalte ersetzte Spalten (zweizeilig immer versteckt)
    private var replaced: Set<String> { twoText ? Set(parts.compactMap(\.column)) : [] }

    private func buildColumns(_ ui: UIPrefs) {
        guard let tv = table, tv.tableColumns.isEmpty else { return }
        let replaced = self.replaced
        let single = model.flatMap { storedLayout("columns.\($0.name)") } ?? ColumnLayout.State()
        let saved = liveMode ? ColumnLayout.State() : twoText ? layoutKey.flatMap(storedLayout) ?? ColumnLayout.twoLine(from: single, replacing: replaced) : single
        let live = liveMode ? LiveList.clampSize(ui.liveListTextSize) : 0
        for id in liveMode ? LiveList.columns : ColumnLayout.placed(saved) {
            guard let d = TrackColumn.byID[id] else { continue }
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            let h = TrackHeaderCell(textCell: d.title)
            h.font11 = TableStyle.mono(11.z)
            c.headerCell = h
            c.title = d.title
            if liveMode {
                let w = LiveList.width(id, size: live)
                c.minWidth = w.min
                c.maxWidth = w.max
                c.width = w.ideal
                c.resizingMask = w.min == w.max ? [] : [.autoresizingMask, .userResizingMask]
                c.isHidden = false
            } else {
                c.minWidth = d.min.z
                c.maxWidth = d.max == .greatestFiniteMagnitude ? d.max : d.max.z
                c.width = d.fixed ? d.width.z : Swift.min(c.maxWidth, Swift.max(c.minWidth, saved.widths[id] ?? d.width.z))
                c.resizingMask = d.fixed ? [] : [.autoresizingMask, .userResizingMask]
                c.isHidden = id == "preview" ? ui.previewMode != .column : id == "track" ? !twoText
                    : replaced.contains(id) ? true : saved.hidden[id] ?? d.hidden
            }
            if d.sort != nil { c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
            tv.addTableColumn(c)
        }
    }

    /// gespeicherte Anordnung: aus den Einstellungen (`AppPrefs.columns`), sonst die frühere Ablage in den Standardwerten
    private func storedLayout(_ key: String) -> ColumnLayout.State? {
        mix?.prefs.columns[key] ?? E2E.defaults.data(forKey: key).flatMap(ColumnLayout.decode)
    }

    private func scheduleSave() {
        guard !Session.isSelfTest else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Anordnung jetzt in die Einstellungen (verzögertes Schreiben abwarten entfällt): beim Ausblenden der Tabelle und
    /// beim Beenden, sonst ginge die letzte Änderung verloren
    func flushLayout() {
        guard !Session.isSelfTest, saveWork != nil else { return }
        saveWork?.cancel()
        saveWork = nil
        save()
    }

    /// alle lebenden Tabellen (Beenden der App)
    nonisolated(unsafe) private static let live = NSHashTable<TrackTableController>.weakObjects()
    override init() { super.init(); Self.live.add(self) }
    static func flushAll() { for c in live.allObjects { c.flushLayout() } }

    private func save() {
        guard let tv = table, let key = layoutKey else { return }
        var s = ColumnLayout.State()
        let replaced = self.replaced
        for c in tv.tableColumns {
            let id = c.identifier.rawValue
            s.order.append(id)
            s.widths[id] = c.width
            // Sammelspalte und ersetzte Spalten folgen dem Modus, nicht der gespeicherten Sichtbarkeit
            if let d = TrackColumn.byID[id], id != "track", !replaced.contains(id), c.isHidden != d.hidden { s.hidden[id] = c.isHidden }
        }
        // nur bei Änderung schreiben (Einstellungen: Speichern und Datei-Export); die frühere Ablage entfällt
        guard let mix, mix.prefs.columns[key] != s else { return }
        mix.prefs.columns[key] = s
        E2E.defaults.removeObject(forKey: key)
    }

    /// Zeilen-Modus, Teile der Sammelspalte oder Live-Modus geändert: Anordnung des alten Modus sichern (im Live-Modus
    /// nichts), Spalten neu aus der des neuen
    private func rebuildColumns(_ ui: UIPrefs, twoText two: Bool, live: Bool) {
        guard let tv = table else { return }
        saveWork?.cancel()
        if !Session.isSelfTest { save() }
        applying = true
        for c in tv.tableColumns { tv.removeTableColumn(c) }
        twoText = two
        liveMode = live
        parts = TrackParts.normalized(ui.trackParts)
        buildColumns(ui)
        applying = false
    }

    func tableViewColumnDidMove(_ n: Notification) { redrawVisible(); scheduleSave() }
    func tableViewColumnDidResize(_ n: Notification) { Self.trace("columnDidResize"); redrawVisible(); if !applying { scheduleSave() } }

    /// MIX741_DEBUG_TABLE=1: Neuaufbau / Neuzeichnen der Tabelle protokollieren (Flimmer-Suche)
    static let tracing = ProcessInfo.processInfo.environment["MIX741_DEBUG_TABLE"] == "1"
    nonisolated(unsafe) static var traceCounts: [String: Int] = [:]
    static func trace(_ what: String) {
        guard tracing else { return }
        traceCounts[what, default: 0] += 1
        if traceCounts[what]! <= 5 || traceCounts[what]! % 100 == 0 { print("[table] \(what) #\(traceCounts[what]!)") }
    }

    /// Spalte auf den längsten Text der Liste (Doppelklick auf den Trenner): Kandidaten nach Zeichenzahl (Plex Mono
    /// ist dicktengleich), die längsten 8 genau gemessen; Titel der Kopfzeile muss auch passen
    func fitColumn(_ i: Int) {
        guard let tv = table, i >= 0, i < tv.tableColumns.count else { return }
        let c = tv.tableColumns[i]
        guard let d = TrackColumn.byID[c.identifier.rawValue], !d.fixed, d.id != "track" else { return }
        var best: [(Int, String)] = []   // (Zeichen, Text), die längsten
        var seen: Set<String> = []
        for t in rows {
            guard let s = cellText(d, t), !s.isEmpty, seen.insert(s).inserted else { continue }
            let n = s.utf16.count
            if best.count < 8 { best.append((n, s)); best.sort { $0.0 > $1.0 } }
            else if n > best[best.count - 1].0 { best[best.count - 1] = (n, s); best.sort { $0.0 > $1.0 } }
        }
        var w: CGFloat = 0
        for (_, s) in best { w = Swift.max(w, textWidth(d, s)) }
        let header = NSAttributedString(string: d.title, attributes: TableStyle.attrs(TableStyle.mono(11.z), TableStyle.bone)).size().width + 14.z
        let want = Swift.max(w + 6.z, header, c.minWidth)
        c.width = Swift.min(c.maxWidth, want.rounded(.up))
        redrawVisible()
        scheduleSave()
    }

    /// Breite eines Zellentexts in der Zeilenschrift (Tags als Chips, Key mit Platz für das Harmonie-Zeichen)
    private func textWidth(_ d: TrackColumn, _ s: String) -> CGFloat {
        switch d.kind {
        case .comment2:
            guard let c = chips(s) else { return 0 }
            return CGFloat(CTLineGetTypographicBounds(c.line, nil, nil, nil))
        case .key:
            let slot = look?.ui.harmonyColors == true ? (font.pointSize * 0.95).rounded() : 0
            return slot + NSAttributedString(string: s, attributes: ctAttrs(font, TableStyle.bone)).size().width
        default:
            return NSAttributedString(string: s, attributes: ctAttrs(font, TableStyle.bone)).size().width
        }
    }

    /// Text einer Zelle wie gezeichnet (nil: Spalte ohne Text)
    private func cellText(_ d: TrackColumn, _ t: Track) -> String? {
        switch d.kind {
        case .artist: t.artist
        case .title: t.title
        case let .field(fd): fd.value(of: t)
        case .bpm: t.bpm > 0 ? String(format: "%.2f", t.bpm) : ""
        case .key: t.openKey
        case .harmony: refBPM > 0 ? "+00.0" : ""
        case .groove: refTags.isEmpty ? "" : "⇄ K B H"
        case .time: Theme.time(t.duration)
        case .gain: t.perceivedDb.map { String(format: "%+.1f", $0) } ?? ""
        case .rating: String(repeating: "★", count: Swift.max(0, Swift.min(5, t.rating)))
        case .comment2: t.comment2
        case .plays: t.playsText
        case .lastPlayed: Track.dateText(t.lastPlayed)
        case .importDate: t.importText
        case .bitrate: t.bitrate > 0 ? "\(t.bitrate)" : ""
        case .file: t.fileName
        case .path: t.path
        case .rip: RipChecks.shared.columnText(t.key)
        case .played, .cloud, .analyzed, .info, .color, .cover, .preview, .track: nil
        }
    }

    /// Zoom: Mindest-/Höchstbreiten neu, Breiten mitskalieren (wie vorher mit der SwiftUI-Tabelle)
    private func applyZoom(from old: CGFloat, to new: CGFloat) {
        guard let tv = table, old != new else { return }
        applying = true
        for c in tv.tableColumns {
            guard let d = TrackColumn.byID[c.identifier.rawValue] else { continue }
            let w = d.fixed ? d.width * new : (c.width * new / old * 2).rounded() / 2
            c.minWidth = Swift.min(c.minWidth, d.min * new)
            c.maxWidth = d.max == .greatestFiniteMagnitude ? d.max : d.max * new
            c.width = w
            c.minWidth = d.min * new
            (c.headerCell as? TrackHeaderCell)?.font11 = TableStyle.mono(11 * new)
        }
        applying = false
        tv.intercellSpacing = NSSize(width: (10 * new).rounded(), height: 0)
        scheduleSave()
    }

    // MARK: Abgleich mit dem Modell

    /// Zeilen immer aus `model.shown` (die SwiftUI-Hülle kann eine ältere Liste halten)
    func update(look l: Look) {
        guard let tv = table, let model else { return }
        let newRows = fixedRows ?? model.shown, gen = model.tableGeneration
        let first = look == nil
        if first {
            twoText = l.twoText
            liveMode = l.liveList
            parts = TrackParts.normalized(l.ui.trackParts)
            buildColumns(l.ui)
        }
        let old = look
        look = l
        if let old {
            // Live-Modus ein/aus, Zoom oder Schriftgröße dazu: Spalten neu (feste Breiten ohne Zoom, nichts gespeichert)
            let rebuild = old.twoText != l.twoText || old.liveList != l.liveList || (l.twoText && old.ui.trackParts != l.ui.trackParts)
                || (l.liveList && (old.zoom != l.zoom || old.ui.liveListTextSize != l.ui.liveListTextSize))
            if rebuild { rebuildColumns(l.ui, twoText: l.twoText, live: l.liveList) }
            if old.zoom != l.zoom, !rebuild { applyZoom(from: old.zoom, to: l.zoom) }
            if old.ui.previewMode != l.ui.previewMode, let c = tv.tableColumns.first(where: { $0.identifier.rawValue == "preview" }) {
                c.isHidden = l.ui.previewMode != .column
            }
        }
        let styleChanged = first || old?.ui != l.ui || old?.zoom != l.zoom || old?.twoText != l.twoText || old?.liveList != l.liveList
        if styleChanged {
            if l.liveList {
                let s = LiveList.clampSize(l.ui.liveListTextSize)
                font = LiveList.font(s, l.ui.liveListWeight)
                plainFont = font
                boldFont = LiveList.font(s, .semibold)
                emphasisFont = LiveList.font(s + 1, .semibold)
                badgeFont = TableStyle.mono((s * 0.78).rounded(), bold: true)
            } else {
                let m = TagChipsText.Metrics.of(l.ui)
                font = m.nsFont
                boldFont = TableStyle.mono(m.size, bold: true)
                plainFont = TableStyle.mono(m.size)
                badgeFont = TableStyle.mono((m.size * 0.78).rounded(), bold: true)
                emphasisFont = font
            }
            advance = NSAttributedString(string: "0", attributes: [.font: plainFont]).size().width
            badgeWidths = [:]
            shortValues = l.ui.shortValues
            let h = l.liveList ? LiveList.rowHeight(LiveList.clampSize(l.ui.liveListTextSize)) : TableStyle.rowHeight(l.ui, twoText: l.twoText)
            bandTop = l.ui.previewMode != .fullRow ? nil : l.twoText ? TableStyle.textHeight(l.ui) : (h * 0.5).rounded()
            tv.rowHeight = h
            rowLines = l.liveList || l.ui.browserRowLines
            if let h = tv.headerView, h.frame.height != (24.z).rounded() { h.frame.size.height = (24.z).rounded(); tv.tile() }
        }
        if styleChanged || old?.filter != l.filter { chipCache = [:] }
        if styleChanged { profileCache = [:] }
        let same = rows.count == newRows.count && rows.withUnsafeBufferPointer { a in newRows.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
        if !same || styleChanged {
            Self.trace(styleChanged ? "reload(style: ui \(old?.ui != l.ui) zoom \(old?.zoom != l.zoom))" : "reload(rows)")
            BrowserPaneModel.dropLater(rows)
            rows = newRows
            applying = true
            tv.reloadData()
            applying = false
            applySelection(model.selection)
            if gen != generation, !first { scrollAfterRebuild() }
            onReload?()
        } else if old != l {
            if old?.inline != l.inline { reloadEditor(old?.inline, l.inline) }
            // nur der Tag-Filter anders und die gefilterte Liste unterwegs: mit ihr neu zeichnen, nicht zweimal
            var o = old
            o?.filter = l.filter
            if !(model.listPending && o == l) {
                Self.trace("redraw(look: tick \(old?.tick != l.tick) cloud \(old?.cloud != l.cloud) played \(old?.played != l.played) preview \(old?.preview != l.preview) filter \(old?.filter != l.filter) inline \(old?.inline != l.inline))")
                redrawVisible()
            }
        }
        generation = gen
        if model.selection != shownSelection { applySelection(model.selection) }
        if !same || styleChanged { updateDetail() }
        syncSort(model.sortOrder)
        followPreview()
    }

    // MARK: Harmonie

    /// Bezug, mit dem die Zellen gezeichnet sind (Key-Code, Tempo)
    private var refKey: Int?
    private var refBPM = 0.0
    /// Tag-Gruppen des Bezugs-Tracks (Spalte „Tags ≈“)
    private var refTags = TagProfile()
    /// Gruppen-Profil je Kommentar-2-Text
    private var profileCache: [String: TagProfile] = [:]

    private func profile(_ t: Track) -> TagProfile {
        if let p = profileCache[t.comment2] { return p }
        let e = BrowserPaneModel.tagIndex.entry(t.comment2, separators: look?.ui.tagSeparators ?? " ")
        let p = TagProfile(tags: e.tags, groups: e.groups)
        profileCache[t.comment2] = p
        return p
    }

    /// `≈` ähnlich / `⇄` ergänzend (Regeln aus ⌘, → BROWSER), dann die Gruppen des Masters: gleich in der Gruppenfarbe,
    /// anders grau, fehlt `·`
    private func drawGroove(_ t: Track, _ l: CGRect, _ ctx: CGContext) {
        guard !refTags.isEmpty, let ui = look?.ui else { return }
        let p = profile(t)
        guard !p.isEmpty else { return }
        var rule = ui.match
        rule.groove = .similar
        let similar = rule.matchesTags(p, refTags)
        rule.groove = .complement
        let complement = rule.matchesTags(p, refTags)
        let out = NSMutableAttributedString(string: similar ? "≈" : complement ? "⇄" : " ", attributes: ctAttrs(font, TableStyle.bone))
        let order = ["K", "B", "H"]
        let groups = refTags.primary.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
        for g in groups {
            let v = p.primary[g]
            let color = v == refTags.primary[g] ? NSColor(TagChipStyle.of(g, group: g, ui).fill) : TableStyle.muted
            out.append(NSAttributedString(string: " " + (v == nil ? "·" : g), attributes: ctAttrs(font, color)))
        }
        let line = CTLineCreateWithAttributedString(out)
        ctx.textPosition = CGPoint(x: l.minX, y: (l.midY + (font.ascender + font.descender) / 2).rounded())
        CTLineDraw(fitted(line, font, TableStyle.bone, l.width), ctx)
    }

    /// eigene Beobachtung von Key und Tempo des Bezugs (ohne SwiftUI): ein Wechsel zeichnet nur Key- und Match-Zellen
    /// der sichtbaren Zeilen neu, die Liste bleibt
    private func observeHarmony() {
        guard let mix else { return }
        withObservationTracking { refKey = mix.harmonyKey; refBPM = mix.harmonyBPM; refTags = mix.harmonyTags } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.harmonyChanged() } }
        }
    }

    private func harmonyChanged() {
        let k = refKey, b = refBPM, g = refTags
        observeHarmony()
        if k != refKey { redrawColumns(["key", "harmony"]) } else if b != refBPM { redrawColumns(["harmony"]) }
        if g != refTags { redrawColumns(["groove"]) }
    }

    /// nur diese Spalten der sichtbaren Zeilen neu zeichnen
    private func redrawColumns(_ ids: [String]) {
        guard let tv = table else { return }
        let rects = ids.map { tv.column(withIdentifier: NSUserInterfaceItemIdentifier($0)) }
            .filter { $0 >= 0 && !tv.tableColumns[$0].isHidden }.map { tv.rect(ofColumn: $0) }
        guard !rects.isEmpty else { return }
        tv.enumerateAvailableRowViews { v, _ in
            for r in rects { v.setNeedsDisplay(NSRect(x: r.minX - v.frame.minX, y: 0, width: r.width, height: v.bounds.height)) }
        }
    }

    // MARK: Vorhören

    /// Strich des vorgehörten Tracks: eine Ebene in seiner Zeile, 10 × je Sekunde nachgeführt
    private let playhead: CALayer = {
        let l = CALayer()
        l.backgroundColor = NSColor(Theme.state).cgColor
        l.zPosition = 1
        l.isHidden = true
        l.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        return l
    }()
    private var playheadTimer: Timer?

    /// Bereich verschwindet: Takt des Strichs anhalten
    func detach() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    private func followPreview() {
        let on = look?.preview != nil
        if on, playheadTimer == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.movePlayhead() } }
            RunLoop.main.add(t, forMode: .common)
            playheadTimer = t
        } else if !on {
            playheadTimer?.invalidate()
            playheadTimer = nil
        }
        movePlayhead()
    }

    /// Bildfläche der Vorschau in der Zeile des vorgehörten Tracks (Tabellen-Koordinaten), nur sichtbare Zeilen
    private func previewRect() -> (row: Int, rect: CGRect)? {
        guard let tv = table, let key = look?.preview, let mode = look?.ui.previewMode else { return nil }
        let id = mode == .column ? "preview" : mode == .behindTitle ? "title" : ""
        let c = tv.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
        guard c >= 0, !tv.tableColumns[c].isHidden else { return nil }
        let vis = tv.rows(in: tv.visibleRect)
        for r in vis.location..<Swift.min(rows.count, vis.location + vis.length) where rows[r].key == key {
            let l = line(tv.frameOfCell(atColumn: c, row: r))
            if mode == .column {
                let h = PreviewRenderer.heightPt.z
                return (r, CGRect(x: l.minX, y: (l.midY - h / 2).rounded(), width: l.width, height: h))
            }
            return (r, l.insetBy(dx: 0, dy: 1))
        }
        return nil
    }

    private func movePlayhead() {
        guard let tv = table, let (r, rect) = previewRect(), let f = mix?.previewFraction, f.isFinite,
              let rv = tv.rowView(atRow: r, makeIfNecessary: false), let layer = rv.layer else {
            playhead.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playhead.superlayer !== layer { layer.addSublayer(playhead) }
        let o = tv.rect(ofRow: r).origin
        playhead.frame = CGRect(x: rect.minX - o.x + CGFloat(f) * rect.width - 1, y: rect.minY - o.y, width: 2, height: rect.height)
        playhead.isHidden = false
        CATransaction.commit()
    }

    /// Vorschau-Spalte: Klick ins Bild des vorgehörten Tracks springt (hinter dem Titel bleibt der Klick beim Titel)
    private func seekClick(_ e: NSEvent) -> Bool {
        guard let tv = table, look?.ui.previewMode == .column, let key = look?.preview, let (r, rect) = previewRect() else { return false }
        let p = tv.convert(e.locationInWindow, from: nil)
        guard tv.row(at: p) == r, rect.contains(p), rect.width > 0 else { return false }
        mix?.seekPreview(key, fraction: (p.x - rect.minX) / rect.width)
        movePlayhead()
        return true
    }

    /// Liste aus dem Hintergrund: direkt übernehmen (kein SwiftUI-Durchlauf für die Tabelle)
    func listArrived() {
        guard let look else { return }
        update(look: look)
    }

    private func applySelection(_ sel: Set<String>) {
        guard let tv = table else { return }
        var ix = IndexSet()
        if sel.count == 1, let k = sel.first {
            if let i = rows.firstIndex(where: { $0.key == k }) { ix.insert(i) }
        } else if !sel.isEmpty {
            for (i, t) in rows.enumerated() where sel.contains(t.key) { ix.insert(i) }
        }
        applying = true
        if tv.selectedRowIndexes != ix { tv.selectRowIndexes(ix, byExtendingSelection: false) }
        applying = false
        shownSelection = sel
        updateDetail()
    }

    /// Detailleiste neu angemeldet: aktuellen Track zeigen
    func refreshDetail() { updateDetail(); model?.detail?.refresh() }

    /// Detailleiste: angeklickte Zeile der Auswahl, sonst der einzige gewählte Track, sonst der bisherige (auch ohne
    /// Auswahl: zuletzt angeklickt), bei Mehrfachauswahl ohne ihn die erste gewählte Zeile
    private func updateDetail(clicked: Int = -1) {
        guard let model, let tv = table else { return }
        let sel = model.selection
        var key = detailKey
        if clicked >= 0, clicked < rows.count, sel.contains(rows[clicked].key) { key = rows[clicked].key }
        else if sel.count == 1 { key = sel.first }
        else if !sel.isEmpty, key.map({ !sel.contains($0) }) ?? true, let i = tv.selectedRowIndexes.first, i < rows.count { key = rows[i].key }
        detailKey = key
        guard let bar = model.detail else { return }
        bar.show(key.flatMap { k in store?.byKey[k] ?? rows.first { $0.key == k } }, table: self)
    }

    /// neue Liste (Quelle, Sortierung, Filter): zur Auswahl, sonst nach oben
    private func scrollAfterRebuild() {
        guard let tv = table else { return }
        if let r = tv.selectedRowIndexes.first { tv.scrollRowToVisible(r) } else if tv.numberOfRows > 0 { tv.scrollRowToVisible(0) }
    }

    func scroll(to key: String) {
        guard let tv = table, let r = rows.firstIndex(where: { $0.key == key }) else { return }
        tv.scrollRowToVisible(r)
    }

    /// Teil der Sammelspalte, nach dem sie gerade sortiert (erste passende Sortierspalte), nur zweizeilig
    private var trackSortPart: TrackPart? {
        guard twoText, let model else { return nil }
        for c in model.sortOrder {
            if let p = TrackPart.sortable.first(where: { $0.sort?.keyPath == c.keyPath }), parts.contains(p) { return p }
        }
        return nil
    }

    /// Spalte einer Sortierung: zweizeilig die Sammelspalte für ihre Teile (einmal), sonst die Spalte des Felds
    private func sortColumn(_ c: KeyPathComparator<Track>, track: inout Bool) -> String? {
        if twoText, !track, let p = TrackPart.sortable.first(where: { $0.sort?.keyPath == c.keyPath }), parts.contains(p) {
            track = true
            return "track"
        }
        return TrackColumn.all.first { $0.id != "track" && $0.sort?.keyPath == c.keyPath }?.id
    }

    private func syncSort(_ order: [KeyPathComparator<Track>]) {
        guard let tv = table else { return }
        var track = false
        let want: [NSSortDescriptor] = order.compactMap { c in
            sortColumn(c, track: &track).map { NSSortDescriptor(key: $0, ascending: c.order == .forward) }
        }
        let part = trackSortPart
        // Marke je Sortierspalte: erste ▲ / ▼, weitere mit Rang (▼2, ▼3); Sammelspalte mit dem Teil davor
        for c in tv.tableColumns {
            guard let h = c.headerCell as? TrackHeaderCell else { continue }
            var m = want.firstIndex { $0.key == c.identifier.rawValue }.map { i in (want[i].ascending ? "▲" : "▼") + (i == 0 ? "" : "\(i + 1)") } ?? ""
            if c.identifier.rawValue == "track", !m.isEmpty, let part { m = part.name.uppercased() + " " + m }
            if h.sortMark != m { h.sortMark = m; tv.headerView?.needsDisplay = true }
        }
        if tv.sortDescriptors != want {
            applying = true
            tv.sortDescriptors = want
            applying = false
        }
    }

    /// Klick auf einen Spaltenkopf: die Spalte wird erste Sortierspalte, die bisherigen bleiben dahinter (AppKit reiht
    /// die Deskriptoren so), ein Klick auf die erste dreht die Richtung – höchstens drei Spalten
    static let maxSortKeys = 3

    func tableView(_ tv: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applying, let model else { return }
        let part = trackSortPart ?? .title
        var order: [KeyPathComparator<Track>] = []
        for d in tv.sortDescriptors {
            guard let k = d.key, var c = k == "track" ? part.sort : TrackColumn.byID[k]?.sort else { continue }
            c.order = d.ascending ? .forward : .reverse
            if !order.contains(where: { $0.keyPath == c.keyPath }) { order.append(c) }
        }
        order = Array(order.prefix(Self.maxSortKeys))
        if !order.isEmpty, order != model.sortOrder { model.sortOrder = order }
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !applying, let tv = table, let model else { return }
        var sel = Set<String>()
        for i in tv.selectedRowIndexes where i < rows.count { sel.insert(rows[i].key) }
        shownSelection = sel
        if model.selection != sel { model.selection = sel }
        updateDetail(clicked: tv.clickedRow)
    }

    // MARK: Zellen

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = tv.makeView(withIdentifier: Self.rowID, owner: nil) as? TrackRowView ?? {
            let v = TrackRowView()
            v.identifier = Self.rowID
            return v
        }()
        v.owner = self
        v.needsDisplay = true
        if playhead.superlayer === v.layer { playhead.isHidden = true }
        return v
    }
    private static let rowID = NSUserInterfaceItemIdentifier("row")

    /// nur die Inline-Bearbeitung ist eine Ansicht, alle anderen Zellen zeichnet die Zeile
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let col, row < rows.count, let e = model?.inline, e.key == rows[row].key else { return nil }
        let id = col.identifier.rawValue
        if id == "track" {
            guard twoText, let li = partLine(e.field) else { return nil }
            let f = tv.frameOfCell(atColumn: tv.column(withIdentifier: col.identifier), row: row)
            let l = trackLines(f)[li]
            return editor(e, line: CGRect(x: 0, y: l.minY - f.minY, width: f.width, height: l.height))
        }
        guard InlineEditController.columnFields[id] == e.field else { return nil }
        return editor(e, line: bandTop.map { CGRect(x: 0, y: 0, width: 1, height: $0) })
    }

    /// Spalte, in der das Feld bearbeitet wird (zweizeilig: Sammelspalte für ihre Teile)
    private func editColumn(_ field: TrackField) -> Int? {
        guard let tv = table else { return nil }
        if twoText, partLine(field) != nil { return tv.tableColumns.firstIndex { $0.identifier.rawValue == "track" } }
        return tv.tableColumns.firstIndex { InlineEditController.columnFields[$0.identifier.rawValue] == field }
    }

    /// Inline-Bearbeitung an/aus/gewechselt: nur die betroffenen Zellen
    private func reloadEditor(_ old: InlineEdit?, _ new: InlineEdit?) {
        guard let tv = table else { return }
        var rs = IndexSet(), cs = IndexSet()
        for e in [old, new].compactMap({ $0 }) {
            if let r = rows.firstIndex(where: { $0.key == e.key }) { rs.insert(r) }
            if let c = editColumn(e.field) { cs.insert(c) }
        }
        guard !rs.isEmpty, !cs.isEmpty else { return }
        tv.reloadData(forRowIndexes: rs, columnIndexes: cs)
        for r in rs { tv.rowView(atRow: r, makeIfNecessary: false)?.needsDisplay = true }
    }

    /// sichtbare Zeilen neu zeichnen (Werte, Farben, Vorschauen)
    private func redrawVisible() {
        guard let tv = table else { return }
        tv.enumerateAvailableRowViews { v, _ in v.needsDisplay = true }
    }

    func drawCells(_ rv: TrackRowView, _ dirty: NSRect) {
        guard let tv = table, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = tv.row(for: rv)
        guard r >= 0, r < rows.count else { return }
        let t = rows[r], origin = tv.rect(ofRow: r).origin
        let editing = model?.inline.flatMap { $0.key == t.key ? $0.field : nil }
        var tips: [NSRect] = []
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // gespielt: ganze Zeile gedimmt (⌘, -> BROWSER), nicht in der History-Tabelle (eigene Ansicht); Live: nicht gedimmt
        let dimmed = !liveMode && look?.ui.dimPlayedTracks == true && history?.played.contains(t.key) == true
        inverted = liveMode && rv.isSelected
        defer { inverted = false }
        for (i, col) in tv.tableColumns.enumerated() where !col.isHidden {
            var f = tv.frameOfCell(atColumn: i, row: r)
            f.origin.x -= origin.x
            f.origin.y -= origin.y
            let id = col.identifier.rawValue
            if id == "cloud" || id == "analyzed" || id == "info" || id == "rip" || (liveMode && id == "played") { tips.append(f) }
            guard f.intersects(dirty), let d = TrackColumn.byID[id] else { continue }
            if let editing, id != "track", InlineEditController.columnFields[id] == editing { continue }
            ctx.saveGState()
            ctx.clip(to: f)
            if dimmed { ctx.setAlpha(0.42) }
            if d.id == "track" { drawTrack(t, f, ctx, editing: editing) } else { drawCell(d, t, row: r, in: f, ctx) }
            ctx.restoreGState()
        }
        if tips != rv.tips {
            rv.removeAllToolTips()
            for f in tips { rv.addToolTip(f, owner: rv, userData: nil) }
            rv.tips = tips
        }
    }

    private static func analyzedHelp(_ t: Track) -> String? {
        guard t.analyzed else { return nil }
        return t.ownAnalysis ? String(localized: "analysiert von MINOS-741 (Tempo, Grid, Tonart, Lautheit ganz oder teilweise)") : String(localized: "analysiert in der Collection")
    }

    func toolTip(_ rv: TrackRowView, at p: NSPoint) -> String? {
        guard let tv = table else { return nil }
        let r = tv.row(for: rv)
        let c = tv.column(at: rv.convert(p, to: tv))
        guard r >= 0, r < rows.count, c >= 0 else { return nil }
        let t = rows[r]
        switch tv.tableColumns[c].identifier.rawValue {
        case "cloud": return CloudCell.badge(t.path).help
        case "info":
            let parts = [CloudCell.badge(t.path).help, Self.analyzedHelp(t)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "analyzed": return Self.analyzedHelp(t)
        case "played" where liveMode:
            let rip = RipChecks.shared.open(t.key)
            let parts = [t.fileExists ? CloudCell.badge(t.path).help : String(localized: "Datei fehlt"), Self.analyzedHelp(t),
                         rip.isEmpty ? nil : rip.map { RipChecks.text($0) + " – " + RipChecks.reasons($0) }.joined(separator: "\n")]
                .compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "rip":
            let o = RipChecks.shared.open(t.key)
            return o.isEmpty ? nil : o.map { RipChecks.text($0) + " – " + RipChecks.reasons($0) }.joined(separator: "\n")
        default: return nil
        }
    }

    /// Textbereich der Zelle: ohne Band die ganze Zelle, mit Band (Vorschau „ganze Zeile“) der Teil darüber
    private func line(_ f: CGRect) -> CGRect {
        bandTop.map { CGRect(x: f.minX, y: f.minY, width: f.width, height: $0) } ?? f
    }

    private func drawCell(_ d: TrackColumn, _ t: Track, row: Int, in f: CGRect, _ ctx: CGContext) {
        let l = line(f)
        switch d.kind {
        case .played:
            if liveMode { liveMarkers(t, l, ctx) } else if history?.played.contains(t.key) == true { draw("✓", TableStyle.secondary, l, ctx) }
        case .cloud:
            let b = CloudCell.badge(t.path)
            if !b.glyph.isEmpty { draw(b.glyph, NSColor(b.color), l, ctx, font: b.glyph == "☁" ? .systemFont(ofSize: 13.z) : TableStyle.mono(11.z)) }
        case .analyzed:
            if t.analyzed { draw("✓", t.ownAnalysis ? TableStyle.secondary : TableStyle.muted, l, ctx) }
        case .info:
            // links Cloud-Zeichen, rechts Analyse-Haken – eine schmale Spalte statt zwei
            let b = CloudCell.badge(t.path), half = CGRect(x: l.minX, y: l.minY, width: (l.width / 2).rounded(), height: l.height)
            if !b.glyph.isEmpty { draw(b.glyph, NSColor(b.color), half, ctx, font: b.glyph == "☁" ? .systemFont(ofSize: 13.z) : TableStyle.mono(11.z)) }
            if t.analyzed { draw("✓", t.ownAnalysis ? TableStyle.secondary : TableStyle.muted, half.offsetBy(dx: half.width, dy: 0), ctx) }
        case .color:
            guard t.color > 0, t.color < TableStyle.trackColors.count else { return }
            ctx.setFillColor(TableStyle.trackColors[t.color].cgColor)
            ctx.fill(CGRect(x: (l.midX - 2.z).rounded(), y: l.minY + 1, width: 4.z, height: l.height - 2))
        case .cover:
            let s = 16.z
            let rect = CGRect(x: l.minX, y: (l.midY - s / 2).rounded(), width: s, height: s)
            if let hit = ArtworkCache.shared.cached(t.path, .small) {
                if let img = hit { image(img, rect, 1, ctx) }
            } else {
                fetch("cover|" + t.path, row: row, key: t.key) { await ArtworkCache.shared.image(t.path, .small) }
            }
        case .artist:
            drawText(t.artist, t.loose ? ink(TableStyle.muted) : t.fileExists ? TableStyle.bone : TableStyle.state, l, ctx, font: font, middle: true)
        case .title:
            if look?.ui.previewMode == .behindTitle, let img = preview(t, row: row) { image(img, l.insetBy(dx: 0, dy: 1), 0.25, ctx) }
            drawTitle(t.title, t.loose ? ink(TableStyle.muted) : liveMode && !t.fileExists ? TableStyle.state : TableStyle.bone, l, ctx, font: font)
        case .preview:
            let h = PreviewRenderer.heightPt.z
            if let img = preview(t, row: row) { image(img, CGRect(x: l.minX, y: (l.midY - h / 2).rounded(), width: l.width, height: h), 1, ctx) }
        case let .field(fd):
            draw(fd.value(of: t), TableStyle.bone, l, ctx)
        case .bpm:
            draw(shortValues ? ShortValues.bpm(t.bpm) : t.bpm > 0 ? String(format: "%.2f", t.bpm) : "", TableStyle.bone, l, ctx, font: emphasisFont)
        case .key:
            drawKey(t, l, ctx)
        case .harmony:
            guard refBPM > 0, let off = look?.ui.match.tempoOffset(t.bpm, to: refBPM), let rule = look?.ui.match else { return }
            let v = (off * 10).rounded() / 10
            draw(v == 0 ? "0.0" : String(format: "%+.1f", v), abs(off) <= rule.bpmWindow ? TableStyle.bone : TableStyle.clash, l, ctx)
        case .groove:
            drawGroove(t, l, ctx)
        case .time:
            draw(Theme.time(t.duration), TableStyle.bone, l, ctx)
        case .gain:
            draw(t.perceivedDb.map { String(format: "%+.1f", $0) } ?? "", TableStyle.bone, l, ctx)
        case .rating:
            draw(String(repeating: "★", count: Swift.max(0, Swift.min(5, t.rating))), TableStyle.bone, l, ctx)
        case .comment2:
            drawChips(t.comment2, l, ctx)
        case .plays:
            draw(t.playsText, TableStyle.bone, l, ctx)
        case .lastPlayed:
            draw(shortValues ? Self.shortDate(t.lastPlayed) : Track.dateText(t.lastPlayed), TableStyle.bone, l, ctx)
        case .importDate:
            draw(shortValues ? Self.shortDate(t.importDate) : t.importText, TableStyle.bone, l, ctx)
        case .bitrate:
            draw(t.bitrate > 0 ? "\(t.bitrate)" : "", TableStyle.bone, l, ctx)
        case .file:
            draw(t.fileName, TableStyle.bone, l, ctx)
        case .path:
            // ganzer Pfad, Mitte gekürzt (Anfang und Dateiname bleiben lesbar)
            drawText(t.path, t.fileExists ? TableStyle.muted : TableStyle.state, l, ctx, font: font, middle: true)
        case .rip:
            draw(RipChecks.shared.columnText(t.key), TableStyle.state, l, ctx)
        case .track:
            break
        }
    }

    /// Key, mit Bezug (Master) nach Harmonie gefärbt und mit Zeichen davor (◆ ▲ ▼ ◇) in einem festen Platz
    private func drawKey(_ t: Track, _ l: CGRect, _ ctx: CGContext) {
        guard look?.ui.harmonyColors == true, let ref = refKey else { draw(t.openKey, TableStyle.bone, l, ctx, font: emphasisFont); return }
        let slot = (font.pointSize * 0.95).rounded()
        let text = CGRect(x: l.minX + slot, y: l.minY, width: l.width - slot, height: l.height)
        guard let code = t.harmonyCode else { draw(t.openKey, TableStyle.clash, text, ctx, font: emphasisFont); return }
        let r = Harmony.relation(code, to: ref), color = TableStyle.harmony(r.step)
        if !r.symbol.isEmpty { draw(r.symbol, color, l, ctx, font: TableStyle.mono(font.pointSize * 0.7)) }
        draw(t.openKey, color, text, ctx, font: emphasisFont)
    }

    private func ctAttrs(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): (inverted ? TableStyle.void : color).cgColor]
    }

    /// Live: alle Zustände in der Markerspalte am Zeilenanfang, je Zustand ein fester Platz (LiveList.markerSlot):
    /// gespielt ✓, Datei (✕ fehlt, ☁ nur online, ↓ lädt, ● lokal, · ungeprüft), analysiert ✓, Rip-Befund.
    /// Zustandsfarben wie sonst, der Rest knochenweiß
    private func liveMarkers(_ t: Track, _ l: CGRect, _ ctx: CGContext) {
        let w = LiveList.markerSlot(font.pointSize)
        func at(_ k: Int, _ s: String, _ c: NSColor, _ f: NSFont? = nil) {
            draw(s, c, CGRect(x: l.minX + CGFloat(k) * w, y: l.minY, width: w, height: l.height), ctx, font: f)
        }
        if history?.played.contains(t.key) == true { at(0, "✓", TableStyle.bone) }
        if !t.fileExists {
            at(1, "✕", TableStyle.state)
        } else {
            let b = CloudCell.badge(t.path)
            if !b.glyph.isEmpty {
                at(1, b.glyph, b.glyph == "●" || b.glyph == "·" ? TableStyle.bone : NSColor(b.color), b.glyph == "☁" ? .systemFont(ofSize: font.pointSize) : nil)
            }
        }
        if t.analyzed { at(2, "✓", TableStyle.bone) }
        let rip = RipChecks.shared.columnText(t.key)
        if !rip.isEmpty { at(3, rip, TableStyle.state) }
    }

    /// Live-Modus: Nebenspalten knochenweiß statt gedämpft (Zustandsfarben bleiben)
    private func ink(_ c: NSColor) -> NSColor { liveMode ? TableStyle.bone : c }

    /// eine Zeile Text, vertikal mittig, rechts mit „…“ gekürzt
    private func draw(_ s: String, _ color: NSColor, _ l: CGRect, _ ctx: CGContext, font f: NSFont? = nil) {
        guard !s.isEmpty else { return }
        let font = f ?? self.font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: ctAttrs(font, color)))
        draw(line, font, color, l, ctx)
    }

    private func draw(_ line: CTLine, _ font: NSFont, _ color: NSColor, _ l: CGRect, _ ctx: CGContext) {
        ctx.textPosition = CGPoint(x: l.minX, y: (l.midY + (font.ascender + font.descender) / 2).rounded())
        CTLineDraw(fitted(line, font, color, l.width), ctx)
    }

    /// zu lang: rechts mit „…“ gekürzt
    private func fitted(_ line: CTLine, _ font: NSFont, _ color: NSColor, _ width: CGFloat) -> CTLine {
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) else { return line }
        let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: ctAttrs(font, color)))
        // gekürzt kann die Zeile über die Breite ragen (Abstand vor „…“): dann um den Überstand enger
        var w = Double(width), out = line
        for _ in 0..<3 {
            out = CTLineCreateTruncatedLine(line, w, .end, dots) ?? line
            let over = CTLineGetTypographicBounds(out, nil, nil, nil) - Double(width)
            if over <= 0.5 { break }
            w -= over
        }
        return out
    }

    private func image(_ img: CGImage, _ r: CGRect, _ alpha: CGFloat, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .medium
        ctx.translateBy(x: 0, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// Bilder, die gerade im Hintergrund entstehen (je Schlüssel einmal); fertig -> Zeile neu, Bild aus dem Cache
    private var fetching: Set<String> = []
    private func fetch(_ id: String, row: Int, key: String, _ work: @escaping () async -> CGImage?) {
        guard fetching.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            _ = await work()
            guard let self else { return }
            self.fetching.remove(id)
            guard let tv = self.table, row < self.rows.count, self.rows[row].key == key else { return }
            tv.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    private func preview(_ t: Track, row: Int) -> CGImage? {
        guard let mix else { return nil }
        let spec = PreviewSpec(t, mix: mix)
        if spec.gen == 0 { Overviews.shared.want(t) }
        let h = spec.hashValue
        if let img = PreviewImages.cached(h) { return img }
        fetch("preview|\(h)", row: row, key: t.key) { await PreviewImages.render(spec) }
        return nil
    }

    /// Kommentar 2 als Chips: Hintergründe an den Stellen von `TagChipsText.spans` (dort wertet auch der Klick aus),
    /// darüber der Text als eine Zeile
    private struct Chips { let line: CTLine; let spans: [ClosedRange<CGFloat>]; let fills: [NSColor?]; let struck: [Bool] }
    private var chipCache: [String: Chips] = [:]

    private func chips(_ s: String) -> Chips? {
        guard !s.isEmpty, let l = look else { return nil }
        if let hit = chipCache[s] { return hit }
        let e = BrowserPaneModel.tagIndex.entry(s, separators: l.ui.tagSeparators).shown(groups: l.ui.tagGroups)
        let out = NSMutableAttributedString()
        var fills: [NSColor?] = [], struck: [Bool] = []
        for (i, tag) in e.tags.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: " ", attributes: ctAttrs(font, TableStyle.bone))) }
            let m = l.filter.isEmpty ? .none : l.filter.mark(key: e.keys[i])
            let st = chipColors(tag, e.groups[i], l.ui)
            let color: NSColor
            switch m {
            case .include: fills.append(st.fill); color = TableStyle.void
            case .exclude: fills.append(nil); color = TableStyle.muted
            case .none: fills.append(st.marker.alphaComponent > 0 ? st.marker : nil); color = TableStyle.bone
            }
            struck.append(m == .exclude)
            out.append(NSAttributedString(string: TagChipsText.inset + tag + TagChipsText.inset, attributes: ctAttrs(font, color)))
        }
        let c = Chips(line: CTLineCreateWithAttributedString(out), spans: TagChipsText.spans(tags: e.tags, TagChipsText.Metrics.of(l.ui)), fills: fills, struck: struck)
        chipCache[s] = c
        return c
    }

    private func drawChips(_ s: String, _ l: CGRect, _ ctx: CGContext) {
        guard let c = chips(s) else { return }
        let line = fitted(c.line, font, TableStyle.bone, l.width)
        let shown = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let h = ceil(font.ascender - font.descender)
        let y = (l.midY - h / 2).rounded()
        for (i, sp) in c.spans.enumerated() where sp.lowerBound < shown {
            let r = CGRect(x: l.minX + sp.lowerBound, y: y, width: Swift.min(sp.upperBound, shown) - sp.lowerBound, height: h)
            if let fill = c.fills[i] { ctx.setFillColor(fill.cgColor); ctx.fill(r) }
            if c.struck[i] {
                ctx.setFillColor(TableStyle.state.cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.midY.rounded(), width: r.width, height: 1))
            }
        }
        ctx.textPosition = CGPoint(x: l.minX, y: (l.midY + (font.ascender + font.descender) / 2).rounded())
        CTLineDraw(line, ctx)
    }

    private var chipColorCache: [String: (marker: NSColor, fill: NSColor)] = [:]
    private func chipColors(_ tag: String, _ group: String?, _ ui: UIPrefs) -> (marker: NSColor, fill: NSColor) {
        guard ui.tagHighlight else { return (.clear, TableStyle.bone) }
        let hex = TagColors.hex(tag, group: group, ui)
        if let c = chipColorCache[hex] { return c }
        let st = TagChipStyle.of(tag, group: group, ui)
        let c = (NSColor(st.marker), NSColor(st.fill))
        chipColorCache[hex] = c
        return c
    }

    // MARK: Werte kürzen, Sammelspalte

    /// kurzes Datum (je Tag einmal gerechnet)
    private static var dateCache: [Int: String] = [:]
    static func shortDate(_ d: Date?) -> String {
        guard let d else { return "" }
        let day = Int(d.timeIntervalSinceReferenceDate / 86400)
        if let s = dateCache[day] { return s }
        let s = ShortValues.date(d, locale: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "de"))
        dateCache[day] = s
        return s
    }

    /// Version am Titelende (je Titel einmal erkannt)
    private var versions: [String: (base: String, short: String)?] = [:]
    private func version(_ title: String) -> (base: String, short: String)? {
        if let hit = versions[title] { return hit }
        let v = ShortValues.version(title)
        versions[title] = v
        return v
    }

    /// Text in einer Zeile: Werte kürzen -> zu lang in der Mitte gekürzt (Plex Mono: Zeichen = Breite / Dickte), sonst rechts
    private func drawText(_ s: String, _ color: NSColor, _ l: CGRect, _ ctx: CGContext, font f: NSFont, middle: Bool) {
        var s = s
        if middle, shortValues, advance > 0 {
            let n = Int(((l.width + 1) / advance).rounded(.down))
            if s.count > n { s = ShortValues.middle(s, max: n) }
        }
        draw(s, color, l, ctx, font: f)
    }

    private func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: ctAttrs(f, TableStyle.bone))), nil, nil, nil))
    }

    /// Breite des Versions-Kürzels samt Abstand davor (je Kürzel einmal gemessen, neu mit der Schrift)
    private var badgeWidths: [String: CGFloat] = [:]
    private func badgeWidth(_ short: String) -> CGFloat {
        if let w = badgeWidths[short] { return w }
        let w = textWidth(short, badgeFont) + 6.z + (advance * 0.6).rounded()
        badgeWidths[short] = w
        return w
    }

    /// Titel; Werte kürzen: Version als Kürzel-Kästchen am Ende (bleibt sichtbar), Titel davor in der Mitte gekürzt
    private func drawTitle(_ title: String, _ color: NSColor, _ l: CGRect, _ ctx: CGContext, font f: NSFont) {
        guard shortValues, let v = version(title) else { drawText(title, color, l, ctx, font: f, middle: true); return }
        let bw = badgeWidth(v.short)
        guard l.width > bw + advance * 4 else { drawText(title, color, l, ctx, font: f, middle: true); return }
        var shown = v.base
        let n = Int(((l.width - bw + 1) / advance).rounded(.down))
        if shown.count > n { shown = ShortValues.middle(shown, max: n) }
        let tw = Swift.min(CGFloat(shown.count) * advance, l.width - bw)
        draw(shown, color, CGRect(x: l.minX, y: l.minY, width: l.width - bw, height: l.height), ctx, font: f)
        let gap = (advance * 0.6).rounded(), w = bw - gap
        let h = ceil(badgeFont.ascender - badgeFont.descender) + 1
        let r = CGRect(x: (l.minX + tw + gap).rounded(), y: (l.midY - h / 2).rounded(), width: w, height: h)
        ctx.setFillColor(TableStyle.bone.withAlphaComponent(0.13).cgColor)
        ctx.fill(r)
        draw(v.short, TableStyle.bone.withAlphaComponent(0.8), r.insetBy(dx: 3.z, dy: 0), ctx, font: badgeFont)
    }

    /// Lage eines Teils der Sammelspalte (Koordinaten wie die Zelle)
    struct PartBox { let part: TrackPart; let rect: CGRect; let line: Int }

    /// zwei Textzeilen mittig im Textbereich der Zelle
    func trackLines(_ f: CGRect) -> [CGRect] {
        let a = line(f), step = TableStyle.lineStep(font.pointSize)
        let top = (a.midY - step).rounded()
        return [CGRect(x: a.minX, y: top, width: a.width, height: step), CGRect(x: a.minX, y: top + step, width: a.width, height: step)]
    }

    /// Zeile (0 / 1) eines Felds in der Sammelspalte, nil = kein Teil
    func partLine(_ field: TrackField) -> Int? {
        let (a, b) = TrackParts.lines(parts)
        if a.contains(where: { $0.field == field }) { return 0 }
        if b.contains(where: { $0.field == field }) { return 1 }
        return nil
    }

    /// Felder der Sammelspalte in Lesereihenfolge (Tab der Inline-Bearbeitung); einzeilig leer
    var trackFields: [TrackField] { twoText ? TrackParts.fields(parts) : [] }

    private func partText(_ p: TrackPart, _ t: Track) -> String {
        switch p {
        case .title: t.title
        case .artist: t.artist
        case .comment: t.comment
        case .tags: t.comment2
        case .label: t.label
        case .album: t.album
        case .remixer: t.remixer
        case .lineBreak: ""
        }
    }

    /// Breite, die ein Teil ungekürzt braucht (0 = leer)
    private func naturalWidth(_ p: TrackPart, _ t: Track) -> CGFloat {
        switch p {
        case .tags:
            guard let c = chips(t.comment2) else { return 0 }
            return CGFloat(CTLineGetTypographicBounds(c.line, nil, nil, nil))
        case .title:
            guard !t.title.isEmpty else { return 0 }
            if shortValues, let v = version(t.title) { return CGFloat(v.base.count) * advance + badgeWidth(v.short) }
            return CGFloat(t.title.count) * advance
        default:
            return CGFloat(partText(p, t).count) * advance
        }
    }

    /// Teile beider Zeilen nebeneinander, getrennt durch „ · “. Zu wenig Platz: gleich verteilt, kurze Teile behalten
    /// ihre Breite, der Rest teilt sich den Platz
    func trackLayout(_ t: Track, _ f: CGRect) -> [PartBox] {
        let lines = trackLines(f), (a, b) = TrackParts.lines(parts)
        return place(a, t, lines[0], 0) + place(b, t, lines[1], 1)
    }

    private func place(_ ps: [TrackPart], _ t: Track, _ l: CGRect, _ li: Int) -> [PartBox] {
        var items: [(TrackPart, CGFloat)] = []
        for p in ps { let w = naturalWidth(p, t); if w > 0 { items.append((p, w)) } }
        guard !items.isEmpty else { return [] }
        let sep = 3 * advance
        var alloc = items.map(\.1), open = Set(items.indices)
        var rest = Swift.max(0, l.width - sep * CGFloat(items.count - 1))
        if alloc.reduce(0, +) > rest {
            while !open.isEmpty {
                let share = rest / CGFloat(open.count)
                let small = open.filter { items[$0].1 <= share }
                if small.isEmpty { for i in open { alloc[i] = share }; break }
                for i in small { rest -= items[i].1; open.remove(i) }
            }
        }
        var x = l.minX, out: [PartBox] = []
        for (i, it) in items.enumerated() {
            out.append(PartBox(part: it.0, rect: CGRect(x: x, y: l.minY, width: alloc[i].rounded(.up), height: l.height), line: li))
            x += alloc[i] + sep
        }
        return out
    }

    /// Sammelspalte zeichnen: Titel kräftig, Artist 70 %, Kommentar / Album 55 %, Label gedämpft, Tags als Chips
    private func drawTrack(_ t: Track, _ f: CGRect, _ ctx: CGContext, editing: TrackField?) {
        let boxes = trackLayout(t, f)
        let dot = TableStyle.muted
        for (i, b) in boxes.enumerated() {
            if i > 0, boxes[i - 1].line == b.line {
                let prev = boxes[i - 1].rect
                draw("·", dot, CGRect(x: prev.maxX + advance, y: b.rect.minY, width: advance, height: b.rect.height), ctx, font: plainFont)
            }
            guard b.part.field != editing else { continue }
            switch b.part {
            case .title: drawTitle(t.title, t.loose ? TableStyle.muted : TableStyle.bone, b.rect, ctx, font: boldFont)
            case .artist: drawText(t.artist, t.fileExists ? TableStyle.bone.withAlphaComponent(0.7) : TableStyle.state, b.rect, ctx, font: plainFont, middle: true)
            case .remixer: drawText(t.remixer, TableStyle.bone.withAlphaComponent(0.7), b.rect, ctx, font: plainFont, middle: true)
            case .comment: draw(t.comment, TableStyle.bone.withAlphaComponent(0.55), b.rect, ctx, font: plainFont)
            case .album: draw(t.album, TableStyle.bone.withAlphaComponent(0.55), b.rect, ctx, font: plainFont)
            case .label: draw(t.label, TableStyle.muted, b.rect, ctx, font: plainFont)
            case .tags: drawChips(t.comment2, b.rect, ctx)
            case .lineBreak: break
            }
        }
    }

    /// Sammelspalte unter einem Punkt (Tabellen-Koordinaten): Feld des Teils (leere Stelle: erster Teil der Zeile) und
    /// Tag-Chip (nur ganz sichtbare). nil = nicht die Sammelspalte bzw. unter dem Text (Band)
    func trackHit(row r: Int, column c: Int, at p: NSPoint) -> (field: TrackField?, tag: String?)? {
        guard twoText, let tv = table, r >= 0, r < rows.count, c >= 0, c < tv.tableColumns.count,
              tv.tableColumns[c].identifier.rawValue == "track" else { return nil }
        let f = tv.frameOfCell(atColumn: c, row: r), t = rows[r]
        let lines = trackLines(f)
        let li: Int
        if p.y < lines[0].maxY { li = 0 } else if p.y < lines[1].maxY || bandTop == nil { li = 1 } else { return nil }
        let box = trackLayout(t, f).first { $0.line == li && $0.rect.minX <= p.x && p.x < $0.rect.maxX }
        var tag: String?
        if let box, box.part == .tags, let l = look, let ch = chips(t.comment2) {
            let x = p.x - box.rect.minX
            let tags = BrowserPaneModel.tagIndex.entry(t.comment2, separators: l.ui.tagSeparators).shown(groups: l.ui.tagGroups).tags
            if let i = ch.spans.firstIndex(where: { $0.contains(x) && $0.upperBound <= box.rect.width }), i < tags.count { tag = tags[i] }
        }
        let (a, b) = TrackParts.lines(parts)
        return (box?.part.field ?? (li == 0 ? a : b).first?.field, tag)
    }

    /// Key-Farbe wie in der Key-Spalte (Harmonie zum Master)
    func keyColor(_ t: Track) -> NSColor {
        guard look?.ui.harmonyColors == true, let ref = refKey else { return TableStyle.bone }
        guard let code = t.harmonyCode else { return TableStyle.clash }
        return TableStyle.harmony(Harmony.relation(code, to: ref).step)
    }

    var tagFilter: TagFilter { look?.filter ?? TagFilter() }

    private func editor(_ e: InlineEdit, line: CGRect?) -> NSView {
        guard let model, let ctl = inline else { return NSView() }
        if e.field == .rating {
            let v = StarsCell()
            v.value = Int(model.inlineText) ?? 0
            v.font = TableStyle.mono(13.z)
            v.lineRect = line
            v.set = { [weak model, weak ctl] n in
                guard let model, let ctl else { return }
                model.inlineText = String(n)
                ctl.finish(e, commit: true, move: 0)
            }
            return v
        }
        let v = InlineFieldCell()
        v.model = model
        v.lineRect = line
        v.finish = { [weak ctl] e, commit in ctl?.finish(e, commit: commit, move: 0) }
        v.configure(e, text: model.inlineText, font: TableStyle.mono(11.z))
        return v
    }

    /// Tippen springt (Spalte der Sortierung)
    func tableView(_ tv: NSTableView, typeSelectStringFor col: NSTableColumn?, row: Int) -> String? {
        guard let col, row < rows.count else { return nil }
        let id = col.identifier.rawValue
        let sortID = tv.sortDescriptors.first?.key ?? "artist"
        guard id == sortID, let d = TrackColumn.byID[id] else { return nil }
        if d.id == "track" { return (trackSortPart ?? .title).field?.value(of: rows[row]) }
        switch d.kind {
        case .artist: return rows[row].artist
        case .title: return rows[row].title
        case let .field(f): return f.value(of: rows[row])
        case .comment2: return rows[row].comment2
        case .file: return rows[row].fileName
        case .path: return rows[row].path
        default: return nil
        }
    }

    // MARK: Aktionen

    @objc private func doubleClicked() {
        guard let tv = table, tv.clickedRow >= 0, tv.clickedRow < rows.count, let mix else { return }
        mix.load(rows[tv.clickedRow], deck: mix.focusedDeck)
    }

    private func returnKey() {
        guard let model else { return }
        inline?.beginFromKeyboard(model.selection)
    }

    /// Rechtsklick: Zeile in der Auswahl -> ganze Auswahl, sonst nur diese Zeile
    private func menuKeys() -> Set<String> {
        guard let tv = table, let model else { return [] }
        let r = tv.clickedRow
        guard r >= 0, r < rows.count else { return [] }
        return tv.selectedRowIndexes.contains(r) ? model.selection : [rows[r].key]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === table?.headerView?.menu { columnMenu(menu); return }
        guard let store, let model, let mix, let history else { return }
        let ids = menuKeys()
        guard !ids.isEmpty else { return }
        let tracks = { ids.compactMap { store.track($0) } }
        let rows = self.rows
        for i in TrackMenu.browserItems(browserFacts(ids), rip: RipChecks.shared.menuItems(tracks: tracks, single: ids.count == 1 ? ids.first.flatMap { store.track($0) } : nil),
                                        browserActions(ids, rows: rows, tracks: tracks, store: store, model: model, mix: mix, history: history)) {
            menu.addItem(i.make())
        }
    }

    /// Rechtsklick auf den Kopf: Spalten ein/aus (Vorschau-Spalte folgt der Einstellung)
    private func columnMenu(_ menu: NSMenu) {
        guard let tv = table else { return }
        for c in tv.tableColumns.sorted(by: { a, b in
            (TrackColumn.all.firstIndex { $0.id == a.identifier.rawValue } ?? 0) < (TrackColumn.all.firstIndex { $0.id == b.identifier.rawValue } ?? 0)
        }) {
            let id = c.identifier.rawValue
            guard id != "preview", id != "track", !replaced.contains(id), let d = TrackColumn.byID[id] else { continue }
            let item = ActionItem(d.menuTitle ?? d.title) { [weak self, weak c] in
                guard let c else { return }
                c.isHidden.toggle()
                self?.scheduleSave()
            }
            item.state = c.isHidden ? .off : .on
            menu.addItem(item)
        }
        // aktuelle Sortierung: je Spalte ein Eintrag zum Herausnehmen, dazu Zurücksetzen
        guard let model else { return }
        // Sammelspalte: nach welchem Teil (wird erste Sortierspalte, bisherige dahinter)
        if twoText {
            menu.addItem(.separator())
            let head = NSMenuItem(title: String(localized: "Spalte Track sortieren nach"), action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            let current = trackSortPart
            for p in TrackPart.sortable where parts.contains(p) {
                guard let c = p.sort else { continue }
                let item = ActionItem(p.name) { [weak model] in
                    guard let model else { return }
                    model.sortOrder = Array(([c] + model.sortOrder.filter { $0.keyPath != c.keyPath }).prefix(Self.maxSortKeys))
                }
                item.state = current == p ? .on : .off
                menu.addItem(item)
            }
        }
        let order = model.sortOrder
        menu.addItem(.separator())
        let title = NSMenuItem(title: String(localized: "Sortierung (Klick auf den Kopf = erste Spalte, bisherige dahinter)"), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for (i, c) in order.enumerated() {
            let name = TrackColumn.all.first { $0.sort?.keyPath == c.keyPath }.map { $0.menuTitle ?? $0.title } ?? "?"
            let mark = (c.order == .forward ? "▲" : "▼") + (i == 0 ? "" : "\(i + 1)")
            let item = ActionItem(order.count > 1 ? String(localized: "\(name) \(mark) herausnehmen") : "\(name) \(mark)") { [weak model] in
                guard let model, model.sortOrder.count > 1 else { return }
                model.sortOrder.removeAll { $0 == c }
            }
            item.isEnabled = order.count > 1
            menu.addItem(item)
        }
        menu.addItem(ActionItem(String(localized: "Sortierung zurücksetzen (Artist)")) { [weak model] in model?.sortOrder = [KeyPathComparator(\Track.artist)] })
    }
}

/// SwiftUI-Hülle: NSScrollView mit der Tabelle, misst nicht (nimmt den angebotenen Platz)
struct TrackTableView: NSViewRepresentable {
    let controller: TrackTableController
    let look: TrackTableController.Look
    /// nur beobachtet: Auswahl und Sortierung des Bereichs
    let selection: Set<String>
    let sort: [KeyPathComparator<Track>]
    /// Modell, Stores, Inline-Controller anbinden (vor dem ersten Abgleich)
    let wire: (TrackTableController) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let v = controller.makeView()
        wire(controller)
        return v
    }

    func updateNSView(_ v: NSScrollView, context: Context) { controller.update(look: look) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }
}
