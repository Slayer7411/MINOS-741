import AppKit
import os
import QuartzCore
import SwiftUI
import MixCore
import MixEngine

/// Was die Wellenform zeigt – ändert sich selten. Pro Frame wird nur verschoben (Textur auf der GPU, Shader-Offset).
struct WaveScene: Equatable {
    struct Mark: Equatable {
        var t: Double, number: Int, rgba: [CGFloat]
        /// Active Loop: Ende des Loops (gestrichelter Rahmen über den Loop)
        var activeEnd: Double?
        init(t: Double, number: Int, color: NSColor, activeEnd: Double? = nil) {
            self.t = t; self.number = number; self.activeEnd = activeEnd
            let c = color.usingColorSpace(.sRGB) ?? color
            rgba = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        }
        var color: NSColor { NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]) }
    }
    var waveID: ObjectIdentifier?
    var duration: Double = 0
    var grid: BeatGrid?
    var span = 4.0
    var showGrid = true
    var colorful = true
    var phraseBeats = 64
    var barNumbers = true
    var barMarkers = true
    /// Beatgrid kräftig (breitere, deckendere Linien) statt fein
    var boldLines = false
    var dimPlayed = true
    /// Marken der anderen Decks (mit Grid) oben am Spielkopf
    var peerMarks = true
    var cues: [Mark] = []
    var cuePoint: Double = 0
    var hasTrack = false
    /// Zoom des Hauptfensters (Schrift, Lineal, Marken)
    var zoom: CGFloat = 1
    /// Grid von Hand gesetzt: Anker-Fahne rot
    var gridEdited = false
    /// Schnitt (außerhalb gedimmt) und EDIT-Modus (Griffe mit IN / OUT)
    struct Trim: Equatable { var start: Double?, end: Double?, editing = false }
    var trim = Trim()
    /// markierter Bereich (⌃ + Ziehen): Fläche, Ränder, Beschriftung Takt.Beat → Takt.Beat · Beats · Sekunden
    struct Marked: Equatable {
        var start: Double, end: Double, label: String
        /// `rip`: Bereich aus einem Befund der Rip-Prüfung („RIP · …“)
        init(_ r: TrackRange, grid: BeatGrid?, rip: Bool = false) {
            start = r.start; end = r.end
            let secs = String(format: "%.1f s", r.length)
            if let g = grid, g.bpm > 0 {
                label = "\(TrackRange.barBeat(r.start, grid: g)) → \(TrackRange.barBeat(r.end, grid: g)) · \(r.beatsText(grid: g)) B · \(secs)"
            } else {
                label = "\(CutRow.Content.time(r.start)) → \(CutRow.Content.time(r.end)) · \(secs)"
            }
            if rip { label = "RIP · " + label }
        }
    }
    var range: Marked?
    /// EDIT-Modus mit Schnittliste (Ausgabe-Zeit): Nähte (Schnitt rot, Marke hell), stumme Stücke gedimmt
    struct EditMarks: Equatable {
        var joints: [Double] = []
        var cuts: [Bool] = []
        /// [Anfang, Ende] je stummem Stück
        var muted: [[Double]] = []
        /// Deck spielt die gerenderte Liste
        var previewing = false
        /// wird gerechnet
        var pending = false
        var segments = 1
    }
    var edit: EditMarks?

    /// ändert sich das, müssen die Wellenform-Kacheln neu gerechnet werden
    var tileKey: String { "\(waveID.map { "\($0)" } ?? "-")|\(duration)|\(span)|\(hasTrack)" }
}

/// Ein anderes Deck für die Marke in der Wellenform: Grid, Position (s), Abspielgeschwindigkeit, läuft
struct WaveformPeer {
    var grid: BeatGrid
    var position: Double
    var speed: Double
    var playing: Bool
}

struct WaveLayerView: NSViewRepresentable {
    let scene: WaveScene
    let wave: RenderedWaveform?
    let position: @MainActor () -> Double
    let stamp: @MainActor () -> (pos: Double, at: Double, speed: Double)?
    /// Abspielgeschwindigkeit (s je s, 0 = steht) – Spielkopf zwischen den Meldungen des Kerns
    let speed: @MainActor () -> Double
    let loop: @MainActor () -> (active: Bool, start: Double, end: Double)
    /// der Loop ist der Auto-Loop vom Laden: auch inaktiv gezeigt (Bone, AUTO)
    var autoLoop: @MainActor () -> Bool = { false }
    /// andere Decks für die Marken (nil = kein Track / Grid, oder das Deck selbst)
    var peer: @MainActor (Int) -> WaveformPeer? = { _ in nil }

    func makeNSView(context: Context) -> WaveLayerNSView { WaveLayerNSView() }

    func updateNSView(_ v: WaveLayerNSView, context: Context) {
        v.position = position
        v.speed = speed
        v.stamp = stamp
        v.loop = loop
        v.autoLoop = autoLoop
        v.peer = peer
        v.wave = wave
        v.scene = scene
    }

    /// nimmt den angebotenen Platz; ohne das misst SwiftUI die NSView bei jedem Layout über Auto Layout (fittingSize)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveLayerNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Wellenform-Ansicht ohne SwiftUI im Frame-Takt. Drei Ebenen im scrollenden Streifen:
/// Kacheln (Bitmaps der Wellenform, im Hintergrund gerendert, nur rund um den Spielkopf), Beatgrid, Cues.
/// Vektor-Pfade pro Frame zu zeichnen hat den Render-Server ausgelastet (Hauptthread wartete in CA synchronize).
final class WaveLayerNSView: NSView {
    var position: @MainActor () -> Double = { 0 }
    var speed: @MainActor () -> Double = { 0 }
    /// Position mit Hörzeit (Stempel); nil = ohne, dann gilt `position`
    var stamp: @MainActor () -> (pos: Double, at: Double, speed: Double)? = { nil }
    var loop: @MainActor () -> (active: Bool, start: Double, end: Double) = { (false, 0, 0) }
    var autoLoop: @MainActor () -> Bool = { false }
    var peer: @MainActor (Int) -> WaveformPeer? = { _ in nil }
    var wave: RenderedWaveform? { didSet { if wave !== oldValue { rebuild(tiles: true) } } }
    var scene = WaveScene() {
        didSet {
            guard scene != oldValue else { return }
            // nur Cues (Hotcue setzen/löschen, Cue-Punkt) oder Schnitt geändert: Grid bleibt – es neu zu bauen kostete ~4 ms
            var a = scene, b = oldValue
            (a.cues, a.cuePoint, b.cues, b.cuePoint) = ([], 0, [], 0)
            (a.trim, b.trim) = (WaveScene.Trim(), WaveScene.Trim())
            (a.range, b.range) = (nil, nil)
            (a.edit, b.edit) = (nil, nil)
            (a.peerMarks, b.peerMarks) = (true, true)
            if a == b, builtSize == bounds.size {
                if scene.peerMarks != oldValue.peerMarks { step() }
                if scene.cues != oldValue.cues || scene.cuePoint != oldValue.cuePoint { rebuildCues() }
                if scene.trim != oldValue.trim { layoutTrim() }
                if scene.range != oldValue.range { layoutRange() }
                if scene.edit != oldValue.edit { layoutEdit() }
            } else { rebuild(tiles: scene.tileKey != oldValue.tileKey) }
        }
    }

    private let content = CALayer()   // gespiegelt: y nach unten
    private let strip = CALayer()
    private let tiles = CALayer(), gridLayer = CALayer(), cueLayer = CALayer()
    private let loopLayer = CALayer()
    private let loopLabel = CATextLayer()
    /// UI-Test: Auto-Loop-Rahmen mit AUTO sichtbar (Bereich in s)
    private(set) var autoLoopShown: (start: Double, end: Double)?
    // Schnitt: gedimmt davor / dahinter, Ränder als Linie, im EDIT-Modus Griffe mit IN / OUT
    private let trimLayer = CALayer(), trimDimLo = CALayer(), trimDimHi = CALayer(), trimLineLo = CALayer(), trimLineHi = CALayer()
    private let trimFlagLo = CATextLayer(), trimFlagHi = CATextLayer()
    // markierter Bereich: Fläche, Ränder mit Laschen, Beschriftung oben
    private let rangeLayer = CALayer(), rangeFill = CALayer(), rangeEdges = CAShapeLayer(), rangeLabel = CATextLayer()
    // Schnittliste: stumme Stücke, Marken, Schnitte
    private let editLayer = CALayer(), editMuted = CAShapeLayer(), editMarks = CAShapeLayer(), editCuts = CAShapeLayer()
    private let dim = CALayer()
    private let playhead = CALayer()
    private let countdown = CATextLayer()
    // andere Decks: je Deck eine Marke am Spielkopf (oben), Lage pro Bild, Form nur bei Änderung
    private var peerTags = (0..<MixEngine.deckCount).map { PeerTag(letter: deckLetters[$0]) }
    private var peerSmoothers = [PlayheadSmoother](repeating: PlayheadSmoother(), count: MixEngine.deckCount)
    private var link: CADisplayLink?
    private var builtSize: CGSize = .zero
    private var pps: Double = 1   // Punkte pro Sekunde bei aktuellem Zoom
    private var lastLoop: (Bool, Double, Double, Bool) = (false, 0, 0, false)
    private var lastCountdown = ""
    private var lastPos = Double.nan
    /// Kern meldet je Audio-Block, Bilder kommen öfter oder versetzt: Spielkopf je Bild gleichmäßig weiter
    private var smoother = PlayheadSmoother()

    // Kacheln
    private static let tileQueue = DispatchQueue(label: "minos741.wavetiles", qos: .userInitiated)
    private static let tileWidth: CGFloat = 1024   // Punkte
    private var tileLayers: [Int: CALayer] = [:]
    private var tilesPending: Set<Int> = []
    private var tileGen = 0

    private static let rulerHeight: CGFloat = 14
    private static let playheadWidth: CGFloat = 2.5
    private var ruler: CGFloat { Self.rulerHeight * scene.zoom }
    private static let monoBold = CTFontCreateWithName("IBMPlexMono-SemiBold" as CFString, 9, nil)

    /// Marke eines anderen Decks: Fähnchen mit Buchstabe und Dreieck darunter; am Rand Pfeil und Text („B +2 BARS“)
    private final class PeerTag {
        struct Look: Equatable { var clamped = false, left = false, beats = 0, inPhase = false, playing = true }
        let letter: String
        let root = CALayer(), box = CALayer(), tri = CAShapeLayer(), text = CATextLayer()
        var look: Look?
        /// Breite der Marke (Punkte) – am Rand mit Text breiter
        var width: CGFloat = 0

        init(letter: String) {
            self.letter = letter
            for l in [root, box, tri, text] as [CALayer] { l.actions = WaveLayerNSView.noAnimation }
            text.font = WaveLayerNSView.monoBold
            text.alignmentMode = .center
            root.isHidden = true
            root.addSublayer(tri)
            root.addSublayer(box)
            box.addSublayer(text)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        content.isGeometryFlipped = true
        content.anchorPoint = .zero
        content.actions = Self.noAnimation
        layer?.addSublayer(content)
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(Theme.wave).cgColor
        strip.anchorPoint = .zero
        loopLayer.backgroundColor = NSColor(Theme.state).withAlphaComponent(0.2).cgColor
        loopLayer.borderColor = NSColor(Theme.state).cgColor
        loopLayer.borderWidth = 1.5
        loopLayer.isHidden = true
        loopLabel.string = "AUTO"
        loopLabel.font = Self.monoBold
        loopLabel.foregroundColor = NSColor(Theme.bone).withAlphaComponent(0.6).cgColor
        loopLabel.actions = Self.noAnimation
        loopLabel.isHidden = true
        loopLayer.addSublayer(loopLabel)
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        playhead.backgroundColor = NSColor(Theme.state).cgColor
        playhead.shadowColor = NSColor.black.cgColor
        playhead.shadowOpacity = 0.6
        playhead.shadowRadius = 1
        playhead.shadowOffset = .zero
        countdown.font = Self.monoBold
        countdown.fontSize = 10
        countdown.contentsScale = 2
        for l in [trimDimLo, trimDimHi] { l.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor }
        for (f, t) in [(trimFlagLo, "IN"), (trimFlagHi, "OUT")] {
            f.string = t; f.font = Self.monoBold; f.alignmentMode = .center
            f.foregroundColor = NSColor.black.cgColor; f.backgroundColor = NSColor(Theme.bone).cgColor
        }
        for l in [trimDimLo, trimDimHi, trimLineLo, trimLineHi, trimFlagLo, trimFlagHi] as [CALayer] {
            l.actions = Self.noAnimation
            trimLayer.addSublayer(l)
        }
        trimLayer.isHidden = true
        rangeFill.backgroundColor = NSColor(Theme.state).withAlphaComponent(0.16).cgColor
        rangeEdges.fillColor = NSColor(Theme.state).cgColor
        rangeLabel.font = Self.monoBold
        rangeLabel.foregroundColor = NSColor(Theme.bone).cgColor
        rangeLabel.backgroundColor = NSColor(Theme.state).cgColor
        rangeLabel.alignmentMode = .center
        for l in [rangeFill, rangeEdges, rangeLabel] as [CALayer] {
            l.actions = Self.noAnimation
            rangeLayer.addSublayer(l)
        }
        rangeLayer.isHidden = true
        editMuted.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        editMarks.fillColor = NSColor(Theme.bone).withAlphaComponent(0.85).cgColor
        editCuts.fillColor = NSColor(Theme.state).cgColor
        for l in [editMuted, editMarks, editCuts] as [CALayer] {
            l.actions = Self.noAnimation
            editLayer.addSublayer(l)
        }
        editLayer.isHidden = true
        for l in [tiles, gridLayer, loopLayer, cueLayer, trimLayer, editLayer, rangeLayer] { strip.addSublayer(l) }
        for l in [strip, dim, playhead, countdown] { content.addSublayer(l) }
        for t in peerTags { content.addSublayer(t.root) }
        for l in [strip, tiles, gridLayer, cueLayer, loopLayer, trimLayer, editLayer, rangeLayer, dim, playhead, countdown] as [CALayer] {
            l.actions = Self.noAnimation
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let noAnimation: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(), "contents": NSNull(), "string": NSNull(),
        "foregroundColor": NSNull(), "sublayers": NSNull(),
    ]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        // Messung offscreen: der Display-Link der Ansicht läuft nur, wenn sie auf dem Bildschirm ist -> der des Bildschirms
        let l = Self.benching ? (NSScreen.main ?? NSScreen.screens[0]).displayLink(target: self, selector: #selector(tick))
            : displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild(tiles: true) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild(tiles: true)
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    // MARK: Aufbau (nur bei Änderungen)

    /// Grid und Cues neu; die Kacheln nur, wenn sich Wellenform, Zoom oder Größe geändert haben
    /// Messung (MIX741_BENCH=browser, Abschnitt split): Aufbauten seit Start (rebuild = Grid + Cues, grid = Gitter, tiles = Kacheln leeren)
    static var builds = (rebuild: 0, grid: 0, tiles: 0)

    private func rebuild(tiles rebuildTiles: Bool) {
        Self.builds.rebuild += 1
        if rebuildTiles { Self.builds.tiles += 1 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let w = bounds.width, h = bounds.height
        builtSize = bounds.size
        content.frame = bounds
        dim.frame = CGRect(x: 0, y: 0, width: w / 2, height: h)
        dim.isHidden = !scene.dimPlayed || !scene.hasTrack
        let pw = Self.playheadWidth * scene.zoom
        playhead.frame = CGRect(x: px(Double(w / 2) - pw / 2), y: 0, width: pw, height: h)
        loopLayer.borderWidth = 1.5 * scene.zoom
        loopLabel.fontSize = 8 * scene.zoom
        loopLabel.contentsScale = scale
        countdown.fontSize = 10 * scene.zoom
        countdown.contentsScale = scale
        playhead.isHidden = !scene.hasTrack
        countdown.isHidden = true
        lastCountdown = ""
        strip.isHidden = !scene.hasTrack
        guard scene.hasTrack, w > 0, h > 0 else { clearTiles(); return }
        pps = Double(w) / (scene.span * 2)
        let total = CGFloat(scene.duration * pps)
        strip.frame = CGRect(x: 0, y: 0, width: total, height: h)
        if rebuildTiles { clearTiles() }
        tiles.frame = strip.bounds
        gridLayer.sublayers = nil
        gridLayer.frame = strip.bounds
        cueLayer.sublayers = nil
        cueLayer.frame = strip.bounds
        lastLoop = (false, -1, -1, false)
        lastPos = .nan
        if scene.showGrid, let g = scene.grid, g.bpm > 0 { buildGrid(g, h: h) }
        buildCues(h: h)
        layoutTrim()
        layoutRange()
        layoutEdit()
        step()
    }

    /// Schnittliste: stumme Stücke gedimmt, Marken als helle Linie mit Lasche oben, Schnitte rot mit Laschen oben und unten
    private func layoutEdit() {
        guard let e = scene.edit, scene.hasTrack, bounds.height > 0, scene.duration > 0 else {
            editLayer.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let h = bounds.height, z = scene.zoom, tab = 6 * z
        editLayer.isHidden = false
        editLayer.opacity = e.pending ? 0.5 : 1
        editLayer.frame = strip.bounds
        for l in [editMuted, editMarks, editCuts] { l.frame = strip.bounds }
        let muted = CGMutablePath()
        for m in e.muted where m.count == 2 {
            let x0 = px(m[0] * pps), x1 = px(m[1] * pps)
            muted.addRect(CGRect(x: x0, y: ruler, width: max(1, x1 - x0), height: h - ruler))
        }
        editMuted.path = muted
        let marks = CGMutablePath(), cuts = CGMutablePath()
        for (k, t) in e.joints.enumerated() {
            let x = px(t * pps), cut = e.cuts.indices.contains(k) && e.cuts[k]
            let l = line(x, width: (cut ? 2 : 1.5) * z, y: 0, height: h)
            let p = cut ? cuts : marks
            p.addRect(l)
            p.addRect(CGRect(x: l.midX - tab / 2, y: 0, width: tab, height: tab))
            if cut { p.addRect(CGRect(x: l.midX - tab / 2, y: h - tab, width: tab, height: tab)) }
        }
        editMarks.path = marks
        editCuts.path = cuts
    }

    /// markierter Bereich: nur Rahmen verschieben (beim Ziehen je Änderung)
    private func layoutRange() {
        guard let r = scene.range, scene.hasTrack, bounds.height > 0, scene.duration > 0 else {
            rangeLayer.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let h = bounds.height, z = scene.zoom
        rangeLayer.isHidden = false
        rangeLayer.frame = strip.bounds
        let x0 = px(r.start * pps), x1 = px(r.end * pps)
        rangeFill.frame = CGRect(x: x0, y: ruler, width: max(1, x1 - x0), height: h - ruler)
        // Ränder 2 pt, Laschen oben und unten nach innen (zum Nachziehen)
        let p = CGMutablePath(), tab = 5 * z
        for (x, dir) in [(x0, CGFloat(1)), (x1, CGFloat(-1))] {
            let l = line(x, width: 2 * z, y: ruler, height: h - ruler)
            p.addRect(l)
            let tx = dir > 0 ? l.maxX : l.minX - tab
            p.addRect(CGRect(x: tx, y: ruler, width: tab, height: tab))
            p.addRect(CGRect(x: tx, y: h - tab, width: tab, height: tab))
        }
        rangeEdges.frame = strip.bounds
        rangeEdges.path = p
        let size = 8 * z, fh = 11 * z
        rangeLabel.string = r.label
        rangeLabel.fontSize = size
        rangeLabel.contentsScale = scale
        rangeLabel.frame = CGRect(x: x0, y: ruler + 1 * z, width: CGFloat(r.label.count) * size * 0.62 + 8 * z, height: fh)
    }

    /// Schnitt: nur Rahmen verschieben (beim Ziehen eines Griffs je Änderung)
    private func layoutTrim() {
        let t = scene.trim, h = bounds.height, z = scene.zoom
        guard scene.hasTrack, h > 0, scene.duration > 0, t.start != nil || t.end != nil || t.editing else {
            trimLayer.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        trimLayer.isHidden = false
        trimLayer.frame = strip.bounds
        let total = strip.bounds.width
        let x0 = px((t.start ?? 0) * pps), x1 = px((t.end ?? scene.duration) * pps)
        trimDimLo.isHidden = t.start == nil
        trimDimLo.frame = CGRect(x: 0, y: 0, width: max(0, x0), height: h)
        trimDimHi.isHidden = t.end == nil
        trimDimHi.frame = CGRect(x: x1, y: 0, width: max(0, total - x1), height: h)
        // Linie: im EDIT-Modus kräftig (Griff), sonst Haarlinie
        let bone = NSColor(Theme.bone)
        for (l, x, set) in [(trimLineLo, x0, t.start != nil), (trimLineHi, x1, t.end != nil)] {
            l.isHidden = !set && !t.editing
            l.backgroundColor = (t.editing ? bone : bone.withAlphaComponent(0.6)).cgColor
            l.frame = line(x, width: (t.editing ? 2.5 : 1) * z, y: 0, height: h)
        }
        // Fahnen außen am Rand (über dem weggeschnittenen Teil), die Grid-Fahne sitzt innen
        let fh = 11 * z, size = 8 * z
        for (f, x, w) in [(trimFlagLo, x0 - 18 * z, 18 * z), (trimFlagHi, x1, 24 * z)] {
            f.isHidden = !t.editing
            f.fontSize = size
            f.contentsScale = scale
            f.frame = CGRect(x: x, y: ruler + 1 * z, width: w, height: fh)
        }
    }

    private func rebuildCues() {
        guard scene.hasTrack, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        cueLayer.sublayers = nil
        buildCues(h: bounds.height)
        step()   // steht der Display-Link (offscreen), sonst nichts zu tun: Position unverändert
    }

    /// Marken der anderen Decks (mit Track und Grid): Lage je Bild, Form, Farbe und Text nur bei Änderung.
    /// Abstand in Beats gegen den Spielkopf dieses Decks (Phrasen-Raster), Pixel über die Beat-Länge dieses Grids
    private func layoutPeers(pos: Double, grid g: BeatGrid?, t: Double?) {
        let w = bounds.width, z = scene.zoom
        guard scene.peerMarks, let g, g.bpm > 0, w > 0, bounds.height > 0 else {
            for m in peerTags { m.root.isHidden = true }
            return
        }
        let own = g.beatPosition(at: pos), phrase = Double(max(4, scene.phraseBeats))
        let limit = Double(w / 2 - 6 * z)
        for e in 0..<MixEngine.deckCount {
            let tag = peerTags[e]
            guard let p = peer(e) else { tag.root.isHidden = true; continue }
            // Position wie der eigene Spielkopf: zwischen den Meldungen des Kerns gleichmäßig weiter
            var sec = p.position
            if !Self.unsmoothed {
                if let t { sec = peerSmoothers[e].update(raw: p.position, speed: p.speed, at: t) }
                else if !peerSmoothers[e].shown.isNaN { sec = peerSmoothers[e].shown }
            }
            let off = PeerMark.offsetBeats(own: own, other: (sec - p.grid.anchor) / p.grid.beat, phraseBeats: phrase)
            let (dx, clamped) = PeerMark.place(offsetBeats: off, beatSeconds: g.beat, pointsPerSecond: pps, limit: limit)
            let look = PeerTag.Look(clamped: clamped, left: dx < 0, beats: clamped ? Int(off.rounded()) : 0,
                                    inPhase: PeerMark.inPhase(off), playing: p.playing)
            if look != tag.look { applyPeerLook(tag, look) }
            // am Spielkopf zentriert; am Rand an die Kante geklebt. Transaktion nur, wenn sich die Lage ändert
            let rw = tag.width
            let x: CGFloat = clamped ? (look.left ? 0 : w - rw) : w / 2 + CGFloat(dx) - rw / 2
            let target = CGRect(x: px(Double(x)), y: 0, width: rw, height: 12 * z)
            if tag.root.isHidden || target != tag.root.frame {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                tag.root.frame = target
                tag.root.isHidden = false
                CATransaction.commit()
            }
        }
    }

    /// Form, Farbe und Text einer Marke (nur bei Wechsel von Modus, Phase oder Laufen)
    private func applyPeerLook(_ tag: PeerTag, _ look: PeerTag.Look) {
        tag.look = look
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let z = scene.zoom, boxH = 9 * z, size = 8 * z
        let lbl = look.clamped ? PhraseCode.label(beats: look.beats) : nil
        let str = lbl.map { "\(tag.letter) \($0)" } ?? tag.letter
        let boxW = look.clamped ? CGFloat(str.count) * size * 0.62 + 4 * z : 11 * z
        let boxX: CGFloat = look.clamped && look.left ? 6 * z : 0
        tag.width = look.clamped ? boxW + 6 * z : boxW
        let fill = look.inPhase ? NSColor(Theme.secondary) : NSColor(Theme.bone)
        tag.root.opacity = look.playing ? 1 : 0.4   // steht das Deck: gedimmt
        tag.box.frame = CGRect(x: boxX, y: 0, width: boxW, height: boxH)
        tag.box.backgroundColor = fill.cgColor
        tag.text.string = str
        tag.text.fontSize = size
        tag.text.contentsScale = scale
        tag.text.foregroundColor = (look.inPhase ? NSColor(Theme.bone) : NSColor(Theme.wave)).cgColor
        tag.text.frame = CGRect(x: 0, y: 0.5 * z, width: boxW, height: boxH)
        let p = CGMutablePath(), mid = boxH / 2
        if !look.clamped {
            p.move(to: CGPoint(x: boxW / 2 - 3.5 * z, y: boxH))
            p.addLine(to: CGPoint(x: boxW / 2 + 3.5 * z, y: boxH))
            p.addLine(to: CGPoint(x: boxW / 2, y: boxH + 3 * z))
        } else if look.left {
            p.move(to: CGPoint(x: 1 * z, y: mid))
            p.addLine(to: CGPoint(x: 5 * z, y: mid - 3 * z))
            p.addLine(to: CGPoint(x: 5 * z, y: mid + 3 * z))
        } else {
            p.move(to: CGPoint(x: boxW + 5 * z, y: mid))
            p.addLine(to: CGPoint(x: boxW + 1 * z, y: mid - 3 * z))
            p.addLine(to: CGPoint(x: boxW + 1 * z, y: mid + 3 * z))
        }
        p.closeSubpath()
        tag.tri.path = p
        tag.tri.fillColor = fill.cgColor
        tag.tri.frame = CGRect(x: 0, y: 0, width: tag.width, height: 12 * z)
    }

    private func clearTiles() {
        tileGen += 1
        tileLayers.values.forEach { $0.removeFromSuperlayer() }
        tileLayers = [:]
        tilesPending = []
    }

    private func px(_ v: Double) -> CGFloat { (CGFloat(v) * scale).rounded() / scale }

    /// senkrechte Linie um x: Breite in Punkten auf ganze Gerätepixel gerundet, an Pixelkanten ausgerichtet
    /// (x liegt auf einer Kante; eine halb überlappende Haarlinie würde sonst auf zwei Pixel verwischen)
    private func line(_ x: CGFloat, width: CGFloat, y: CGFloat, height: CGFloat) -> CGRect {
        let hair = 1 / scale
        let n = max(1, (width * scale).rounded())
        return CGRect(x: x - (n / 2).rounded(.down) * hair, y: y, width: n * hair, height: height)
    }

    private func shape(_ path: CGPath, _ color: NSColor) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.actions = Self.noAnimation
        s.contentsScale = scale
        s.allowsEdgeAntialiasing = true
        s.path = path
        s.fillColor = color.cgColor
        return s
    }

    private func text(_ str: String, _ color: NSColor, at p: CGPoint, size: CGFloat = 9) -> CATextLayer {
        let size = size * scene.zoom
        let t = CATextLayer()
        t.actions = Self.noAnimation
        t.string = str
        t.font = Self.monoBold
        t.fontSize = size
        t.foregroundColor = color.cgColor
        t.contentsScale = scale
        // Ursprung auf Gerätepixeln: sonst wird das Textbild beim Zusammensetzen verschoben und weich
        t.frame = CGRect(x: px(p.x), y: px(p.y), width: px(CGFloat(str.count) * size * 0.62 + 4), height: px(size + 3))
        return t
    }

    /// Linien des Beatgrids: Breite in pt (× Zoom, auf ganze Gerätepixel gerundet) und Deckung
    struct GridLines: Equatable {
        var beat: CGFloat, beatAlpha: CGFloat, bar: CGFloat, barAlpha: CGFloat, phrase: CGFloat
        var mark8: CGFloat, mark16: CGFloat, mark32: CGFloat, anchor: CGFloat, tick: CGFloat, capAlpha: CGFloat
        /// Haarlinien: Beat 1 Gerätepixel bei 2×
        static let fine = GridLines(beat: 0.5, beatAlpha: 0.35, bar: 1, barAlpha: 0.7, phrase: 1.5,
                                    mark8: 2, mark16: 2.5, mark32: 3, anchor: 2, tick: 0.5, capAlpha: 0.6)
        static let bold = GridLines(beat: 1, beatAlpha: 0.6, bar: 1.5, barAlpha: 1, phrase: 2.5,
                                    mark8: 2.5, mark16: 3.5, mark32: 4.5, anchor: 2.5, tick: 1, capAlpha: 0.85)
    }

    /// zuletzt gebaute Linienbreiten in Gerätepixeln (Beat, Takt) – UI-Selbsttest
    private(set) var gridPixels: (beat: CGFloat, bar: CGFloat) = (0, 0)

    private func buildGrid(_ g: BeatGrid, h: CGFloat) {
        Self.builds.grid += 1
        let r = px(Double(ruler)), z = scene.zoom
        let lw = scene.boldLines ? GridLines.bold : GridLines.fine
        let bone = NSColor(Theme.bone), lila = NSColor(Theme.secondary)
        let phrase = max(4, scene.phraseBeats)
        let first = Int(g.beatPosition(at: 0).rounded(.up))
        let last = Int(g.beatPosition(at: scene.duration).rounded(.down))
        guard last > first, last - first < 5000 else { return }
        let bands = CGMutablePath(), beats = CGMutablePath(), bars = CGMutablePath(), phrases = CGMutablePath()
        let tris = CGMutablePath(), ptris = CGMutablePath(), ticks = CGMutablePath()
        let caps = CGMutablePath(), barCaps = CGMutablePath()
        let m8 = CGMutablePath(), m16 = CGMutablePath(), m32 = CGMutablePath()
        let magenta = NSColor(srgbRed: 0.88, green: 0.22, blue: 0.78, alpha: 1)
        let labels = CALayer()
        labels.actions = Self.noAnimation
        for b in first...last {
            let x = px(g.time(ofBeat: Double(b)) * pps)
            let inBar = ((b % 4) + 4) % 4
            let isPhrase = scene.colorful && ((b % phrase) + phrase) % phrase == 0
            if isPhrase, (((b / phrase) % 2) + 2) % 2 == 1 {
                let x1 = px(g.time(ofBeat: Double(b + phrase)) * pps)
                bands.addRect(CGRect(x: x, y: 0, width: x1 - x, height: h))
            }
            let barIdx = b / 4
            let mark = scene.barMarkers && inBar == 0 ? (barIdx % 32 == 0 ? 32 : barIdx % 16 == 0 ? 16 : barIdx % 8 == 0 ? 8 : 0) : 0
            // Linie auf ganzen Gerätepixeln; Kappen und Dreiecke um ihre Mitte (bei ungerader Pixelzahl ½ Pixel neben x)
            let l: CGRect
            if mark > 0 {
                let mw = mark == 32 ? lw.mark32 : mark == 16 ? lw.mark16 : lw.mark8
                l = line(x, width: mw * z, y: r, height: h - r)
                (mark == 32 ? m32 : mark == 16 ? m16 : m8).addRect(l)
            } else if isPhrase {
                l = line(x, width: lw.phrase * z, y: r, height: h - r)
                phrases.addRect(l)
            } else if inBar == 0 {
                l = line(x, width: lw.bar * z, y: r, height: h - r)
                bars.addRect(l)
                gridPixels.bar = l.width * scale
            } else {
                l = line(x, width: lw.beat * z, y: r, height: h - r)
                beats.addRect(l)
                gridPixels.beat = l.width * scale
            }
            let cx = l.midX
            if inBar == 0 {
                let tp = isPhrase ? ptris : tris
                tp.move(to: CGPoint(x: cx - 6 * z, y: r)); tp.addLine(to: CGPoint(x: cx + 6 * z, y: r))
                tp.addLine(to: CGPoint(x: cx, y: r + 7 * z)); tp.closeSubpath()
                let perPhrase = phrase / 4
                let barInPhrase = (((b / 4) % perPhrase) + perPhrase) % perPhrase + 1
                let label = mark > 0 ? "\(mark)" : isPhrase ? "P\(b / phrase + 1)" : (scene.barNumbers ? "\(barInPhrase)" : "")
                if !label.isEmpty {
                    labels.addSublayer(text(label, mark > 0 ? magenta : isPhrase ? lila : bone, at: CGPoint(x: x + 3 * z, y: 1 * z)))
                }
            } else {
                ticks.addRect(line(x, width: lw.tick * z, y: r - px(5 * z), height: px(5 * z)))
            }
            // Kappen oben und unten (Takt breiter), Kanten auf Gerätepixeln: Pixelzahl mit derselben Parität wie die Linie
            var cp = ((inBar == 0 ? 8 : 6) * z * scale).rounded()
            if Int(cp - (l.width * scale).rounded()) % 2 != 0 { cp += 1 }
            let cw = cp / scale, ch = px(2 * z)
            let cap = inBar == 0 ? barCaps : caps
            cap.addRect(CGRect(x: cx - cw / 2, y: r, width: cw, height: ch))
            cap.addRect(CGRect(x: cx - cw / 2, y: px(Double(h)) - ch, width: cw, height: ch))
        }
        // Lineal ohne eigene Abdunklung: Phrasen-Tönung läuft über die ganze Höhe
        gridLayer.addSublayer(shape(bands, lila.withAlphaComponent(0.08)))
        gridLayer.addSublayer(shape(beats, bone.withAlphaComponent(lw.beatAlpha)))
        gridLayer.addSublayer(shape(bars, bone.withAlphaComponent(lw.barAlpha)))
        gridLayer.addSublayer(shape(caps, bone.withAlphaComponent(lw.capAlpha)))
        gridLayer.addSublayer(shape(barCaps, bone))
        gridLayer.addSublayer(shape(phrases, lila))
        gridLayer.addSublayer(shape(m8, magenta.withAlphaComponent(0.8)))
        gridLayer.addSublayer(shape(m16, magenta.withAlphaComponent(0.95)))
        gridLayer.addSublayer(shape(m32, magenta))
        gridLayer.addSublayer(shape(ticks, bone.withAlphaComponent(lw.beatAlpha + 0.25)))
        gridLayer.addSublayer(shape(tris, bone))
        gridLayer.addSublayer(shape(ptris, lila))
        gridLayer.addSublayer(labels)
        // Grid-Anker
        let ax = px(g.anchor * pps)
        let anchor = CGMutablePath(), flag = CGMutablePath()
        anchor.addRect(line(ax, width: lw.anchor * z, y: 0, height: h))
        flag.addRect(CGRect(x: ax, y: r, width: px(10 * z), height: px(10 * z)))
        gridLayer.addSublayer(shape(anchor, bone))
        // Fahne: von Hand gesetzt rot (Zustand, die Linie bleibt hell – rot ist der Spielkopf), sonst knochenweiß
        gridLayer.addSublayer(shape(flag, scene.gridEdited ? NSColor(Theme.state) : bone))
        gridLayer.addSublayer(text("G", scene.gridEdited ? bone : .black, at: CGPoint(x: ax + 1.5 * z, y: r - 1 * z), size: 8))
        countdown.isHidden = !scene.colorful
    }

    private func buildCues(h: CGFloat) {
        let z = scene.zoom
        for c in scene.cues {
            let x = px(c.t * pps)
            let p = CGMutablePath()
            p.addRect(line(x, width: 2.5 * z, y: 0, height: h))
            p.addRect(CGRect(x: x, y: h - 26 * z, width: 13 * z, height: 12 * z))
            cueLayer.addSublayer(shape(p, c.color))
            cueLayer.addSublayer(text("\(c.number)", .black, at: CGPoint(x: x + 3 * z, y: h - 27 * z), size: 9))
            if let e = c.activeEnd {   // Active Loop: gestrichelter Rahmen in der Cue-Farbe
                let r = CAShapeLayer()
                r.actions = Self.noAnimation
                r.path = CGPath(rect: CGRect(x: x, y: 1 * z, width: max(2, px(e * pps) - x), height: h - 2 * z), transform: nil)
                r.fillColor = nil
                r.strokeColor = c.color.cgColor
                r.lineWidth = 1.5 * z
                r.lineDashPattern = [NSNumber(value: Double(5 * z)), NSNumber(value: Double(4 * z))]
                cueLayer.addSublayer(r)
            }
        }
        let cx = px(scene.cuePoint * pps)
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: cx - 6 * z, y: h)); tri.addLine(to: CGPoint(x: cx + 6 * z, y: h))
        tri.addLine(to: CGPoint(x: cx, y: h - 9 * z)); tri.closeSubpath()
        cueLayer.addSublayer(shape(tri, NSColor(Theme.bone)))
    }

    // MARK: Kacheln (Bitmaps rund um den Spielkopf, im Hintergrund gerendert)

    private func updateTiles(_ pos: Double) {
        guard let wave, scene.hasTrack else { return }
        let tw = Self.tileWidth, w = bounds.width, h = bounds.height
        let total = CGFloat(scene.duration * pps)
        guard total > 0, h > 0 else { return }
        let x0 = max(0, CGFloat(pos * pps) - w / 2), x1 = min(total, x0 + w)
        let maxIndex = max(0, Int((total / tw).rounded(.up)) - 1)
        let first = max(0, Int(x0 / tw) - 1), last = min(maxIndex, Int(x1 / tw) + 1)
        guard first <= last else { return }
        for (i, l) in tileLayers where i < first - 2 || i > last + 2 {
            l.removeFromSuperlayer()
            tileLayers[i] = nil
        }
        for i in first...last where tileLayers[i] == nil && !tilesPending.contains(i) {
            tilesPending.insert(i)
            let gen = tileGen, pps = pps, scale = scale, chunks = wave.chunks, raster = wave.raster
            Self.tileQueue.async {
                let t0 = CACurrentMediaTime()
                let img = Self.renderTile(i, chunks: chunks, raster: raster, pps: pps, h: h, tw: tw, scale: scale)
                Self.tileTime.withLock { $0.count += 1; $0.seconds += CACurrentMediaTime() - t0 }
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.tileGen else { return }
                    self.tilesPending.remove(i)
                    guard let img else { return }
                    let l = CALayer()
                    l.actions = Self.noAnimation
                    l.contents = img
                    l.contentsScale = scale
                    l.contentsGravity = .resize
                    l.frame = CGRect(x: CGFloat(i) * tw, y: 0, width: tw, height: h)
                    self.tiles.addSublayer(l)
                    self.tileLayers[i] = l
                }
            }
        }
    }

    /// Kacheln gerechnet + Zeit dafür (Wellenform-Bild im Selbsttest)
    static let tileTime = OSAllocatedUnfairLock(initialState: (count: 0, seconds: 0.0))

    /// eine Kachel in Bildschirmauflösung zeichnen (Hintergrund-Queue; Pfade und Farben sind unveränderliche CF-Objekte)
    static func renderTile(_ i: Int, chunks: [RenderedWaveform.Chunk], raster: RenderedWaveform.Raster?, pps: Double, h: CGFloat,
                                   tw: CGFloat, scale: CGFloat) -> CGImage? {
        let pw = Int(tw * scale), ph = Int(h * scale)
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let x0 = CGFloat(i) * tw
        // Mischung: je Gerätepixel-Spalte gerastert
        if let raster, let data = ctx.data {
            raster.draw(into: data, bytesPerRow: ctx.bytesPerRow, width: pw, height: ph, t0: Double(x0) / pps, dt: 1 / (pps * Double(scale)))
            return ctx.makeImage()
        }
        ctx.scaleBy(x: scale, y: scale)
        let t0 = Double(x0) / pps, t1 = Double(x0 + tw) / pps
        let chunkSeconds = Double(RenderedWaveform.chunkBlocks) / TrackAudio.blocksPerSecond
        // Umriss-Beschnitt nur, wenn ein Block breiter als ~1 Gerätepixel ist (sonst keine sichtbaren Stufen; die Maske kostet)
        let smooth = pps * Double(scale) / TrackAudio.blocksPerSecond > 1.25
        // Pfade sind um 0 gespiegelt → Ausrichtung der y-Achse spielt keine Rolle
        for c in chunks where c.t0 + chunkSeconds >= t0 && c.t0 <= t1 {
            var t = CGAffineTransform(a: CGFloat(pps), b: 0, c: 0, d: h / 2, tx: CGFloat(c.t0 * pps) - x0, ty: h / 2)
            // Ebenen mit demselben Umriss nacheinander im selben Beschnitt
            var clip: CGPath?, clipped = false
            for l in c.layers {
                guard let p = l.path.copy(using: &t) else { continue }
                if smooth, l.clip !== clip || (clip != nil && !clipped) {
                    if clipped { ctx.restoreGState(); clipped = false }
                    clip = l.clip
                    if let cp = l.clip?.copy(using: &t) {
                        ctx.saveGState()
                        ctx.addPath(cp)
                        ctx.clip()
                        clipped = true
                    }
                }
                ctx.setFillColor(l.color)
                ctx.addPath(p)
                ctx.fillPath()
            }
            if clipped { ctx.restoreGState() }
        }
        return ctx.makeImage()
    }

    // MARK: pro Frame: nur verschieben

    /// nur MIX741_BENCH=play: Takte, Verschiebungen, Zeit in step (inkl. Commit), Bewegung je Bild (Gerätepixel) bei
    /// laufendem Deck. MIX741_BENCH_RAW=1: Spielkopf ungeglättet (Position des Kerns wie gemeldet)
    struct BenchStats { var steps = 0, moves = 0, seconds = 0.0, px: [Double] = [] }
    static var bench = BenchStats()
    static func benchReset() { bench = BenchStats() }
    private static let benching = ToggleBench.mode == "play"
    private static let unsmoothed = benching && ProcessInfo.processInfo.environment["MIX741_BENCH_RAW"] != nil
    private var benchX = Double.nan
    private var lastTick = 0.0

    @objc private func tick(_ link: CADisplayLink) {
        lastTick = link.targetTimestamp
        guard Self.benching else { return step(at: link.targetTimestamp) }
        let t0 = CACurrentMediaTime()
        step(at: link.targetTimestamp)
        Self.bench.steps += 1
        Self.bench.seconds += CACurrentMediaTime() - t0
    }

    /// t = Zeit des Bildes (Display-Link); nil = außerhalb des Takts neu aufgebaut: Spielkopf vom letzten Bild,
    /// lief der Takt nicht (Ansicht verdeckt, offscreen), die gemeldete Position
    private func step(at t: Double? = nil) {
        guard scene.hasTrack else {
            for m in peerTags where !m.root.isHidden { m.root.isHidden = true }
            return
        }
        let st = stamp()
        let raw = st?.pos ?? position()
        let pos: Double
        if Self.unsmoothed { pos = raw }
        else if let t, let st { pos = smoother.update(raw: st.pos, speed: st.speed, at: t, heard: st.at) }   // Kerntempo des Blocks, nicht die Anzeige
        else if let t { pos = smoother.update(raw: raw, speed: speed(), at: t) }
        else { pos = smoother.shown.isNaN || CACurrentMediaTime() - lastTick > 0.05 ? raw : smoother.shown }
        let l = loop(), auto = !l.active && l.end > l.start && autoLoop()
        let loopChanged = l.active != lastLoop.0 || l.start != lastLoop.1 || l.end != lastLoop.2 || auto != lastLoop.3
        let x = ((Double(bounds.width / 2) - pos * pps) * scale).rounded() / scale
        if Self.benching, t != nil, speed() != 0 {
            if !benchX.isNaN { Self.bench.px.append(abs(x - benchX) * scale) }
            benchX = x
        }
        layoutPeers(pos: pos, grid: scene.grid, t: t)   // vor dem Abbruch: die anderen Decks laufen auch, wenn dieses steht
        // Deck steht: nichts verschieben, keine Transaktion (sonst 4 Decks × 120 Hz im Leerlauf)
        if pos == lastPos, !loopChanged, tilesPending.isEmpty { return }
        lastPos = pos
        if Self.benching { Self.bench.moves += 1 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.position = CGPoint(x: x, y: 0)
        updateTiles(pos)
        if loopChanged {
            lastLoop = (l.active, l.start, l.end, auto)
            loopLayer.isHidden = !l.active && !auto
            loopLabel.isHidden = !auto
            autoLoopShown = auto ? (l.start, l.end) : nil
            if l.active || auto {
                let x0 = px(l.start * pps), x1 = px(l.end * pps)
                loopLayer.frame = CGRect(x: x0, y: 0, width: x1 - x0, height: bounds.height)
                let c = auto ? NSColor(Theme.bone) : NSColor(Theme.state)
                loopLayer.backgroundColor = c.withAlphaComponent(auto ? 0.06 : 0.2).cgColor
                // Auto-Schleife ohne Rahmen (lief oben und unten als Linie über den Track), nur Tönung + AUTO
                loopLayer.borderColor = c.withAlphaComponent(auto ? 0 : 1).cgColor
                let z = scene.zoom
                loopLabel.frame = CGRect(x: 4 * z, y: ruler + 3 * z, width: 30 * z, height: 11 * z)
            }
        }
        if !countdown.isHidden, let g = scene.grid {
            let phrase = Double(max(4, scene.phraseBeats))
            let bp = g.beatPosition(at: pos)
            let toNext = phrase - (bp - (bp / phrase).rounded(.down) * phrase)
            let bars = Int((toNext / 4).rounded(.up))
            let s = "P\(Int((bp / phrase).rounded(.down)) + 1) · \(bars) T"
            if s != lastCountdown {
                lastCountdown = s
                countdown.string = s
                countdown.foregroundColor = NSColor(bars <= 1 ? Theme.state : Theme.bone).cgColor
                let z = scene.zoom
                countdown.frame = CGRect(x: bounds.width / 2 + 6 * z, y: ruler + 3 * z, width: 120 * z, height: 14 * z)
            }
        }
        CATransaction.commit()
    }
}
