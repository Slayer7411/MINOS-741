import CoreGraphics
import Observation
import SwiftUI
import MixCore
import MixEngine

/// Vorberechnete Wellenform eines Tracks: Vektor-Abschnitte für die Scroll-Ansicht (GPU zeichnet sie in
/// Bildschirmauflösung, scharf bei jedem Zoom) oder Blockdaten zum Rastern (3-Band Mischung) + ein Übersichtsbild.
final class RenderedWaveform: @unchecked Sendable {
    /// Abschnitt: Pfade in Sekunden (x, ab `t0`) und Amplitude (y, -1…1 = 0 dBFS); `clip` = Umriss, auf den die
    /// Flächen der Ebene beschnitten werden (Blöcke als Rechtecke je Farbe, Kante weich zwischen den Block-Mitten)
    typealias Layer = (color: CGColor, path: CGPath, clip: CGPath?)
    struct Chunk { let t0: Double; let layers: [Layer] }
    static let chunkBlocks = 2048

    /// Mischung: Spitzen und Hüllkurven je Block (Kopie – hält den Track-Puffer nicht fest), gerastert je Kachel
    struct Raster: Sendable {
        let peak: [Float]
        let blend: [UInt8]
        /// je Block Anteil gehaltener Höhen 0…255 (offene Hats hellblau), leer ohne Spektrum
        let open: [UInt8]
        /// je Block Anteil gehaltener Tiefen 0…255 (Bassline / Sub-Ausklang orange, Kick-Anschlag rot)
        let warm: [UInt8]
        let palette: BlendPaint.Palette

        /// Spalten `x0..<x0+width` (Pixel) in ein RGBA-Bild (vormultipliziert): Spalte x deckt die Zeit
        /// `t0 + x·dt …`, `height` Zeilen, volle Höhe = 0 dBFS
        func draw(into data: UnsafeMutableRawPointer, bytesPerRow: Int, width: Int, height: Int, t0: Double, dt: Double) {
            let half = height / 2, bps = TrackAudio.blocksPerSecond
            let px = data.assumingMemoryBound(to: UInt8.self)
            peak.withUnsafeBufferPointer { pk in
                blend.withUnsafeBufferPointer { bl in
                  open.withUnsafeBufferPointer { op in
                   warm.withUnsafeBufferPointer { wm in
                    // Spalte schmaler als ein Block: zwischen den Block-Mitten interpolieren (keine Stufen), sonst Maximum
                    let narrow = dt * bps < 1, n = min(pk.count, bl.count / WaveBlend.stride)
                    for x in 0..<width {
                        let a = t0 + Double(x) * dt, fa = a * bps, fb = (a + dt) * bps
                        // Rundungsfehler: eine Spalte genau auf Blockgrenzen soll den Nachbarblock nicht anschneiden
                        let from = Int((fa + 1e-6).rounded(.down)), to = Int((fb - 1e-6).rounded(.up))
                        guard to > 0, from < n else { continue }
                        let edges = (first: Float(min(1, Double(from + 1) - fa)), last: Float(min(1, fb - Double(to - 1))))
                        BlendPaint.column(peak: pk, blend: bl, open: op.isEmpty ? nil : op, warm: wm.isEmpty ? nil : wm,
                                          from: max(0, from), to: max(from + 1, to), edges: edges,
                                          between: narrow ? .at(a + dt / 2, bps: bps, count: n) : nil, half: half, palette: palette) {
                            j, r, g, b, al in
                            let o = (half - 1 - j) * bytesPerRow + x * 4, u = (height - half + j) * bytesPerRow + x * 4
                            px[o] = r; px[o + 1] = g; px[o + 2] = b; px[o + 3] = al
                            px[u] = r; px[u + 1] = g; px[u + 2] = b; px[u + 3] = al
                        }
                    }
                   }
                  }
                }
            }
        }
    }

    let chunks: [Chunk]
    let raster: Raster?
    let overview: CGImage?
    let duration: Double

    init(chunks: [Chunk], raster: Raster? = nil, overview: CGImage?, duration: Double) {
        self.chunks = chunks
        self.raster = raster
        self.overview = overview
        self.duration = duration
    }

    struct RGB { var r, g, b: CGFloat }

    struct Colors {
        var low: RGB, mid: RGB, high: RGB
        static func of(_ p: WaveformPalette) -> Colors {
            switch p {
            case .rgb: Colors(low: RGB(r: 0.92, g: 0.14, b: 0.10), mid: RGB(r: 0.16, g: 0.86, b: 0.26), high: RGB(r: 0.30, g: 0.50, b: 1.0))
            case .bone: Colors(low: RGB(r: 0.36, g: 0.33, b: 0.30), mid: RGB(r: 0.64, g: 0.60, b: 0.55), high: RGB(r: 0.95, g: 0.93, b: 0.88))
            case .orange: Colors(low: RGB(r: 0.66, g: 0.15, b: 0.04), mid: RGB(r: 1.0, g: 0.60, b: 0.12), high: RGB(r: 1.0, g: 0.96, b: 0.88))
            case .blue: Colors(low: RGB(r: 0.09, g: 0.28, b: 0.90), mid: RGB(r: 1.0, g: 0.60, b: 0.18), high: RGB(r: 1, g: 1, b: 1))
            case .classic: Colors(low: RGB(r: 0.95, g: 0.18, b: 0.08), mid: RGB(r: 0.22, g: 0.88, b: 0.36), high: RGB(r: 0.55, g: 0.68, b: 1.0))
            }
        }
    }

    /// Spektrum (6 Bänder): Farben aus MixCore.SpectrumColors, Höhen als eigene Ebene darüber
    struct Fine {
        let colors: SpectrumColors
        init(_ s: WaveSpectrum, highBoost: Double) {
            colors = SpectrumColors(s, highBoost: highBoost)
        }
        static func rgb(_ c: SpectrumColors.RGB) -> RGB { RGB(r: CGFloat(c.r), g: CGFloat(c.g), b: CGFloat(c.b)) }
        func color(_ L: [Float], sustain: Float) -> (body: RGB, high: CGFloat, highColor: RGB) {
            let c = colors.color(L, sustain: sustain)
            return (Self.rgb(c.body), CGFloat(c.high), Self.rgb(c.highColor))
        }
        func color(_ s: WaveSpectrum, _ i: Int) -> (body: RGB, high: CGFloat, highColor: RGB) {
            let c = colors.color(s, i)
            return (Self.rgb(c.body), CGFloat(c.high), Self.rgb(c.highColor))
        }
    }

    /// Höhen-Ebene: Energieanteil flach abgebildet (Exponent 0,35 statt Wurzel), damit Hats auch unter Kick und Bass sichtbar bleiben
    static func highLevel(_ ratio: Float) -> CGFloat { CGFloat(pow(max(0, ratio), 0.35)) * 0.95 }

    /// Hüllkurve: Anschlag sofort, Abklingen ~20 ms (Kicks als klare Spitzen statt Rauschen)
    private static func envelope(_ a: TrackAudio) -> [Float] {
        var env = [Float](repeating: 0, count: a.peak.count)
        var e: Float = 0
        for i in env.indices { e = max(a.peak[i], e * 0.85); env[i] = e }
        return env
    }

    /// Spektrum-Farbe: Bänder additiv gemischt, auf volle Helligkeit gezogen
    private static func spectrum(_ lo: CGFloat, _ mi: CGFloat, _ hi: CGFloat, _ c: Colors) -> RGB {
        let r = c.low.r * lo + c.mid.r * mi + c.high.r * hi
        let g = c.low.g * lo + c.mid.g * mi + c.high.g * hi
        let b = c.low.b * lo + c.mid.b * mi + c.high.b * hi
        let m = max(r, g, b, 0.0001)
        return RGB(r: r / m, g: g / m, b: b / m)
    }

    /// Spalte → (Spitze, Bass-, Mitten-, Höhenanteil) über mehrere Blöcke (für die Übersicht)
    private static func column(_ a: TrackAudio, env: [Float], from: Int, to: Int) -> (pk: CGFloat, lo: CGFloat, mi: CGFloat, hi: CGFloat) {
        let n = a.peak.count
        let s = max(0, min(n - 1, from)), e = max(s + 1, min(n, to))
        var pk: Float = 0, lo: Float = 0, mi: Float = 0, hi: Float = 0
        for i in s..<e {
            pk = max(pk, env[i]); lo += a.low[i]; mi += a.mid[i]; hi += a.high[i]
        }
        let c = Float(e - s)
        return (CGFloat(pk), CGFloat(lo / c), CGFloat(mi / c), CGFloat(hi / c))
    }

    private static func cg(_ c: RGB) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    /// Umriss oben + gespiegelt unten als ein Polygon
    private static func outline(_ amps: [CGFloat], dt: Double) -> CGPath {
        let p = CGMutablePath()
        guard !amps.isEmpty else { return p }
        p.move(to: CGPoint(x: 0, y: -amps[0]))
        for (i, v) in amps.enumerated() { p.addLine(to: CGPoint(x: (Double(i) + 0.5) * dt, y: -v)) }
        p.addLine(to: CGPoint(x: Double(amps.count) * dt, y: -amps[amps.count - 1]))
        p.addLine(to: CGPoint(x: Double(amps.count) * dt, y: amps[amps.count - 1]))
        for (i, v) in amps.enumerated().reversed() { p.addLine(to: CGPoint(x: (Double(i) + 0.5) * dt, y: v)) }
        p.addLine(to: CGPoint(x: 0, y: amps[0]))
        p.closeSubpath()
        return p
    }

    /// Farbe auf 8 Stufen je Kanal → Schlüssel (wenige Pfade je Abschnitt)
    private static func quantized(_ c: RGB) -> (Int, RGB) {
        let q = { (v: CGFloat) in Int((max(0, min(1, v)) * 7).rounded()) }
        let r = q(c.r), g = q(c.g), b = q(c.b)
        return (r * 64 + g * 8 + b, RGB(r: CGFloat(r) / 7, g: CGFloat(g) / 7, b: CGFloat(b) / 7))
    }

    /// Umriss durch die Block-Mitten (oben + gespiegelt unten) als Beschnitt: `amps` = Blöcke des Abschnitts und der
    /// erste des nächsten (die Kante läuft bis zu dessen Mitte weiter)
    private static func clipOutline(_ amps: [CGFloat], dt: Double) -> CGPath {
        let p = CGMutablePath()
        guard let first = amps.first else { return p }
        p.move(to: CGPoint(x: 0, y: -first))
        for (i, v) in amps.enumerated() { p.addLine(to: CGPoint(x: (Double(i) + 0.5) * dt, y: -v)) }
        for (i, v) in amps.enumerated().reversed() { p.addLine(to: CGPoint(x: (Double(i) + 0.5) * dt, y: v)) }
        p.addLine(to: CGPoint(x: 0, y: first))
        p.closeSubpath()
        return p
    }

    /// Höhe des Rechtecks für Block k: höchster der drei Nachbarn (der Umriss zwischen den Mitten liegt darunter)
    @inline(__always) private static func cover(_ v: [CGFloat], _ k: Int) -> CGFloat {
        max(v[k], v[max(0, k - 1)], v[min(v.count - 1, k + 1)])
    }

    /// feines Spektrum: Blöcke als Rechtecke je Farbe, beschnitten auf den Umriss; optional die Höhen als eigene Ebene darüber
    private static func fineChunk(_ a: TrackAudio, env: [Float], range: Range<Int>, fine: Fine) -> [Layer] {
        let dt = 1 / TrackAudio.blocksPerSecond, n = env.count
        // ein Block Rand je Seite: Höhe der Nachbarn für Umriss und Rechtecke
        let lo = max(0, range.lowerBound - 1), hi = min(n, range.upperBound + 1)
        let cols = (lo..<hi).map { fine.color(a.spectrum, $0) }
        let v = (lo..<hi).map { max(CGFloat(env[$0]), 0.004) }
        let h = (0..<v.count).map { cols[$0].high > 0.02 ? v[$0] * cols[$0].high : 0 }
        var body: [Int: (RGB, CGMutablePath)] = [:], highs: [Int: (RGB, CGMutablePath)] = [:]
        var order: [Int] = []
        for k in 0..<range.count {
            let j = range.lowerBound + k - lo
            let c = cols[j]
            let (key, qc) = quantized(c.body)
            if body[key] == nil { body[key] = (qc, CGMutablePath()); order.append(key) }
            let bv = cover(v, j)
            body[key]!.1.addRect(CGRect(x: Double(k) * dt, y: -bv, width: dt * 1.02, height: bv * 2))
            if h[j] > 0 || cover(h, j) > 0 {
                let (hk, hq) = quantized(c.highColor)
                if highs[hk] == nil { highs[hk] = (hq, CGMutablePath()) }
                let hv = cover(h, j)
                highs[hk]!.1.addRect(CGRect(x: Double(k) * dt, y: -hv, width: dt * 1.02, height: hv * 2))
            }
        }
        let first = range.lowerBound - lo
        let bodyClip = clipOutline(Array(v[first...]), dt: dt), highClip = clipOutline(Array(h[first...]), dt: dt)
        return order.map { (cg(body[$0]!.0), body[$0]!.1 as CGPath, bodyClip) } + highs.values.map { (cg($0.0), $0.1 as CGPath, highClip) }
    }

    private static func chunk(_ a: TrackAudio, env: [Float], range: Range<Int>, style: WaveformStyle, colors: Colors, fine: Fine?) -> [Layer] {
        if let fine { return fineChunk(a, env: env, range: range, fine: fine) }
        let dt = 1 / TrackAudio.blocksPerSecond
        let pk = range.map { CGFloat(env[$0]) }
        switch style {
        case .mono:
            return [(cg(colors.mid), outline(pk, dt: dt), nil)]
        case .blend:
            // ohne Mischungsdaten (alter Cache): drei Amplituden übereinander, Bass hinten, Mitten, Höhen vorn
            let mid = (0..<range.count).map { pk[$0] * CGFloat(a.mid[range.lowerBound + $0] + a.high[range.lowerBound + $0]).squareRoot() }
            let high = (0..<range.count).map { pk[$0] * Self.highLevel(a.high[range.lowerBound + $0]) }
            return [(cg(colors.low), outline(pk, dt: dt), nil), (cg(colors.mid), outline(mid, dt: dt), nil), (cg(colors.high), outline(high, dt: dt), nil)]
        case .spectrum:
            // ohne Spektrumdaten (alter Cache): Farbe je Block aus den drei Anteilen, auf 5 Stufen je Kanal gerundet
            let lo = max(0, range.lowerBound - 1), hi = min(env.count, range.upperBound + 1)
            let v = (lo..<hi).map { max(CGFloat(env[$0]), 0.004) }
            var paths: [Int: (RGB, CGMutablePath)] = [:]
            for k in 0..<range.count {
                let i = range.lowerBound + k
                var c = spectrum(CGFloat(a.low[i]), CGFloat(a.mid[i]), CGFloat(a.high[i]), colors)
                let q = { (v: CGFloat) in (v * 4).rounded() / 4 }
                c = RGB(r: q(c.r), g: q(c.g), b: q(c.b))
                let key = Int(c.r * 4) * 25 + Int(c.g * 4) * 5 + Int(c.b * 4)
                let path = paths[key]?.1 ?? CGMutablePath()
                if paths[key] == nil { paths[key] = (c, path) }
                let bv = cover(v, i - lo)
                path.addRect(CGRect(x: Double(k) * dt, y: -bv, width: dt * 1.02, height: bv * 2))
            }
            let clip = clipOutline(Array(v[(range.lowerBound - lo)...]), dt: dt)
            return paths.values.map { (cg($0.0), $0.1, clip) }
        }
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func drawOverview(_ ctx: CGContext, x: CGFloat, h: CGFloat, col: (pk: CGFloat, lo: CGFloat, mi: CGFloat, hi: CGFloat),
                                     style: WaveformStyle, colors: Colors) {
        let mid = h / 2
        func bar(_ amp: CGFloat, _ c: RGB) {
            let hh = max(0.5, amp * mid)
            ctx.setFillColor(cg(c))
            ctx.fill(CGRect(x: x, y: mid - hh, width: 1, height: hh * 2))
        }
        switch style {
        case .blend:
            bar(col.pk, colors.low)
            bar(col.pk * (col.mi + col.hi).squareRoot(), colors.mid)
            bar(col.pk * highLevel(Float(col.hi)), colors.high)
        case .spectrum:
            bar(col.pk, spectrum(col.lo, col.mi, col.hi, colors))
        case .mono:
            bar(col.pk, colors.mid)
        }
    }

    /// Übersichts-Spalte im feinen Spektrum: mittlere Bandenergie und Höhen-Dauer über die Blöcke der Spalte
    private static func fineColumn(_ a: TrackAudio, env: [Float], from: Int, to: Int, fine: Fine) -> (pk: CGFloat, c: (body: RGB, high: CGFloat, highColor: RGB)) {
        let s = a.spectrum, n = s.count
        let lo = max(0, min(n - 1, from)), hi = max(lo + 1, min(n, to))
        var e = [Float](repeating: 0, count: 6)
        var pk: Float = 0, sus: Float = 0
        for i in lo..<hi {
            pk = max(pk, env[i])
            for b in 0..<6 {
                let v = s.data[i * WaveSpectrum.stride + b]
                if v > 0 { e[b] += powf(10, (Float(v) - 255) / 20) }
            }
            sus += s.sustain(i)
        }
        let c = Float(hi - lo)
        let L = e.map { $0 > 0 ? 10 * log10f($0 / c) : -160 }
        return (CGFloat(pk), fine.color(L, sustain: sus / c))
    }

    /// `preset` gilt für den Stil 3-Band, `blend` = nachgerechnete Hüllkurven (Analyse-Werte des Presets), sonst die der Datei
    static func render(_ a: TrackAudio, style: WaveformStyle, palette: WaveformPalette, highBoost: Double = 1,
                       preset: WavePreset = WavePresets.standard, blend: WaveBlend? = nil, tune: BlendPaint.Tune? = nil,
                       overviewHeight: Int = overviewPixels) -> RenderedWaveform {
        let colors = Colors.of(palette)
        if style == .blend, (blend ?? a.blend).count >= a.peak.count, !a.peak.isEmpty {
            return self.blend(a, palette: preset.palette, data: blend ?? a.blend, tune: tune, overviewHeight: overviewHeight)
        }
        let env = envelope(a)
        let fine = style == .spectrum && a.spectrum.count >= a.peak.count && !a.peak.isEmpty ? Fine(a.spectrum, highBoost: highBoost) : nil
        let dt = 1 / TrackAudio.blocksPerSecond
        var chunks: [Chunk] = []
        var b0 = 0
        while b0 < env.count {
            let r = b0..<min(env.count, b0 + chunkBlocks)
            chunks.append(Chunk(t0: Double(b0) * dt, layers: chunk(a, env: env, range: r, style: style, colors: colors, fine: fine)))
            b0 = r.upperBound
        }
        // Übersicht
        let ow = 1600, oh = overviewHeight
        var overview: CGImage?
        if let ctx = context(width: ow, height: oh), !a.peak.isEmpty {
            let per = Double(a.peak.count) / Double(ow)
            for x in 0..<ow {
                let from = Int(Double(x) * per), to = Int(Double(x + 1) * per)
                if let fine {
                    let (pk, c) = fineColumn(a, env: env, from: from, to: to, fine: fine)
                    let mid = CGFloat(oh) / 2
                    ctx.setFillColor(cg(c.body))
                    ctx.fill(CGRect(x: CGFloat(x), y: mid - max(0.5, pk * mid), width: 1, height: max(1, pk * mid * 2)))
                    if c.high > 0.02 {
                        ctx.setFillColor(cg(c.highColor))
                        ctx.fill(CGRect(x: CGFloat(x), y: mid - pk * c.high * mid, width: 1, height: pk * c.high * mid * 2))
                    }
                    continue
                }
                let col = column(a, env: env, from: from, to: to)
                drawOverview(ctx, x: CGFloat(x), h: CGFloat(oh), col: col, style: style, colors: colors)
            }
            overview = ctx.makeImage()
        }
        return RenderedWaveform(chunks: chunks, overview: overview, duration: a.duration)
    }
}

extension RenderedWaveform {
    /// Pixelhöhe des Übersichtsbilds: Standard (bis 30 pt bei 100 %)
    static let overviewPixels = 60

    /// Pixelhöhe für eine Übersicht von `points` pt bei `zoom` (Retina 2×), in Stufen von 60 px (ein Regler-Schritt
    /// rechnet nicht jedes Mal neu), 60…480
    static func overviewPixels(points: Double, zoom: Double) -> Int {
        let px = points * max(zoom, 0.1) * 2
        return min(480, max(overviewPixels, Int((px / 60).rounded(.up)) * 60))
    }

    /// 3-Band Mischung: keine Pfade, die Kacheln rastern aus den Blöcken; Übersicht gleich gerastert
    static func blend(_ a: TrackAudio, palette: BlendPaint.Palette, data: WaveBlend, tune: BlendPaint.Tune? = nil,
                      overviewHeight: Int = overviewPixels) -> RenderedWaveform {
        var pal = palette
        tune?.apply(to: &pal)   // Versuchswerte, nur im Selbsttest-Bild
        // Anteil gehaltener Höhen je Block aus der Höhen-Dauer des Spektrums (geschlossene Hats blau, offene hellblau)
        let n = a.peak.count
        let open: [UInt8] = a.spectrum.count >= n ? (0..<n).map { UInt8((SpectrumColors.openness(a.spectrum.sustain($0)) * 255).rounded()) } : []
        let blendData = Array(data.data.prefix(n * WaveBlend.stride))
        // gehaltene Tiefen (Bassline, Sub-Ausklang) orange, Kick-Anschläge rot: laufendes Minimum der Tief-Spitze
        let warm = BlendPaint.warmth(blend: blendData, count: n)
        let raster = Raster(peak: BlendPaint.displayPeaks(Array(a.peak)), blend: blendData, open: open, warm: warm, palette: pal)
        let ow = 1600, oh = overviewHeight
        var overview: CGImage?
        if let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data {
            raster.draw(into: data, bytesPerRow: ctx.bytesPerRow, width: ow, height: oh, t0: 0, dt: a.duration / Double(ow))
            overview = ctx.makeImage()
        }
        return RenderedWaveform(chunks: [], raster: raster, overview: overview, duration: a.duration)
    }
}

/// Hält fertige Wellenformen je Track-Puffer und rechnet neue im Hintergrund.
/// Schlüssel ist die Speicheradresse des Puffers – der Eintrag hält ihn schwach und gilt nur, solange genau dieser
/// Puffer lebt (ein neuer Track an derselben Adresse bekäme sonst die Wellenform des alten).
/// Wellenformen entladener Tracks fallen beim nächsten Eintrag weg. Bis die neue fertig ist, bleibt die zuletzt
/// gezeigte desselben Puffers stehen (Preset-Wechsel ohne Lücke).
/// Stil 3-Band mit anderen Analyse-Werten als denen der Datei: Hüllkurven im Hintergrund aus den Samples nachrechnen
/// (je Puffer die letzten Werte gemerkt); ein neuerer Auftrag für denselben Puffer bricht den laufenden ab
@MainActor @Observable
final class WaveformCache {
    private struct Entry { weak var audio: TrackAudio?; let wave: RenderedWaveform }
    private struct Reblend { weak var audio: TrackAudio?; let params: BlendParams; let blend: WaveBlend }
    private var done: [String: Entry] = [:]
    @ObservationIgnored private var running: [String: (audio: ObjectIdentifier, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var shown: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private var reblends: [ObjectIdentifier: Reblend] = [:]
    /// Nachanalysen (Selbsttest): Anzahl und letzte Dauer
    @ObservationIgnored private(set) var reanalyzed = 0
    @ObservationIgnored private(set) var lastReanalysis = 0.0

    func waveform(for audio: TrackAudio?, ui: UIPrefs, preset: WavePreset) -> RenderedWaveform? {
        guard let audio else { return nil }
        let style = ui.waveformStyle, palette = ui.waveformPalette, boost = ui.waveformHighBoost
        let oid = ObjectIdentifier(audio)
        let look = style == .blend ? "\(preset.look.hashValue)-\(preset.analysis.hashValue)" : ""
        let oh = RenderedWaveform.overviewPixels(points: ui.overviewHeight, zoom: ui.zoom)
        let key = "\(oid.hashValue)-\(style.rawValue)-\(palette.rawValue)-\(boost)-\(look)-\(oh)"
        if let e = done[key], e.audio === audio { shown[oid] = key; return e.wave }
        if running[key] == nil {
            for (k, r) in running where r.audio == oid { r.task.cancel(); running[k] = nil }
            let params = style == .blend && preset.analysis != .standard ? preset.analysis : nil
            let cached = params.flatMap { p in reblends[oid].flatMap { $0.audio === audio && $0.params == p ? $0.blend : nil } }
            let task = Task.detached(priority: .userInitiated) {
                var blend = cached
                if let p = params, blend == nil {
                    let t0 = Date()
                    guard let b = BlendAnalyzer.analyze(left: audio.left, right: audio.right, frames: audio.frames, sampleRate: audio.sampleRate,
                                                        blocks: audio.peak.count, params: p, cancelled: { Task.isCancelled }) else { return }
                    blend = b
                    let dt = Date().timeIntervalSince(t0)
                    await MainActor.run {
                        self.reblends = self.reblends.filter { $0.value.audio != nil }
                        self.reblends[oid] = Reblend(audio: audio, params: p, blend: b)
                        self.reanalyzed += 1
                        self.lastReanalysis = dt
                    }
                }
                guard !Task.isCancelled else { return }
                let w = RenderedWaveform.render(audio, style: style, palette: palette, highBoost: boost, preset: preset, blend: blend,
                                                overviewHeight: oh)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.done.removeAll { $0.value.audio == nil || $0.value.audio === audio }   // ältere Fassungen dieses Puffers
                    self.done[key] = Entry(audio: audio, wave: w)
                    self.shown[oid] = key
                    self.running[key] = nil
                    if self.done.count > 16 { self.done.removeAll { $0.key != key } }
                    self.shown = self.shown.filter { self.done[$0.value] != nil }
                }
            }
            running[key] = (oid, task)
        }
        if let k = shown[oid], let e = done[k], e.audio === audio { return e.wave }
        return nil
    }
}

private extension Dictionary {
    mutating func removeAll(where f: (Element) -> Bool) {
        for (k, v) in self where f((k, v)) { self[k] = nil }
    }
}

/// Scrollende Wellenform: Ebenen auf der GPU, pro Frame nur verschoben.
/// Hülle liest Deck und Einstellungen, die Equatable-Ansicht darunter rendert nur bei geänderter Szene neu.
struct WaveformView: View {
    @Environment(MixModel.self) private var mix
    @Environment(WaveformCache.self) private var cache
    let d: Int

    var body: some View {
        let ui = mix.prefs.ui
        let deck = mix.deck(d)
        let wf = cache.waveform(for: mix.audio(d), ui: ui, preset: mix.wavePreset)
        let scene = WaveScene(
            waveID: wf.map { ObjectIdentifier($0) }, duration: deck.duration, grid: deck.grid, span: ui.waveformSeconds,
            showGrid: ui.showBeatgrid, colorful: ui.colorfulGrid, phraseBeats: ui.phraseBeats, barNumbers: ui.showBarNumbers, barMarkers: ui.barMarkers,
            boldLines: ui.gridLineWeight == .bold,
            dimPlayed: ui.dimPlayed, peerMarks: ui.peerMarks,
            cues: deck.hotcues.values.sorted { $0.hotcue < $1.hotcue }.map {
                WaveScene.Mark(t: $0.startMs / 1000, number: $0.hotcue + 1, color: NSColor(Theme.cueColor($0, deck: deck, prefs: mix.prefs)),
                               activeEnd: deck.activeLoops.contains($0.hotcue) ? ($0.startMs + $0.lengthMs) / 1000 : nil)
            },
            cuePoint: deck.cuePoint, hasTrack: deck.track != nil, zoom: 1.z, gridEdited: deck.gridEdited,
            trim: .init(start: deck.trim.start, end: deck.trim.end, editing: mix.editing(d) && !(mix.decks[d].edit?.previewing ?? false)),
            range: mix.rangeMarked(d, grid: deck.grid), edit: mix.editing(d) ? mix.decks[d].edit : nil)
        Content(d: d, scene: scene, wave: wf, waiting: deck.track != nil && wf == nil).equatable()
            .overlay(alignment: .bottomTrailing) { WaveZoomButtons().padding(3.z) }
    }

    /// Griff des Schnitts unter x (0 = Anfang, 1 = Ende), nur im EDIT-Modus; Abstand höchstens 8 pt
    @MainActor static func trimHandle(at x: CGFloat, width: CGFloat, scene: WaveScene, position: Double) -> Int? {
        guard scene.trim.editing, scene.hasTrack, scene.duration > 0, width > 0 else { return nil }
        let secPerPt = scene.span * 2 / Double(width)
        let xs = [scene.trim.start ?? 0, scene.trim.end ?? scene.duration].map { CGFloat(($0 - position) / secPerPt) + width / 2 }
        let dist = xs.map { abs($0 - x) }
        guard let i = dist.indices.min(by: { dist[$0] < dist[$1] }), dist[i] <= 8 * scene.zoom else { return nil }
        return i
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let scene: WaveScene
        let wave: RenderedWaveform?
        let waiting: Bool
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.scene == b.scene && a.wave === b.wave && a.waiting == b.waiting }

        var body: some View {
            WaveLayerView(scene: scene, wave: wave, position: { [mix, d] in mix.position(d) }, stamp: { [mix, d] in mix.positionStamp(d) },
                          speed: { [mix, d] in mix.playSpeed(d) },
                          loop: { [mix, d] in mix.engine.loop(d) }, autoLoop: { [mix, d] in mix.deck(d).autoLoop },
                          peer: { [mix, d] e in e == d ? nil : mix.peerDeck(e) })
                .overlay {
                    if waiting {
                        Text("Wellenform wird berechnet …").font(Theme.mono(10.z)).foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                .overlay { WaveMouse(mix: mix, d: d, scene: scene) }
        }
    }
}

/// Maus in der Wellenform, in AppKit: ⌃-Klick ist sonst ein Rechtsklick (SwiftUI-Kontextmenü statt Ziehen).
/// Ziehen = Scrub, im EDIT-Modus Griffe des Schnitts; ⌃ + Ziehen markiert einen Bereich (Beatgrid, ⌥ = frei),
/// seine Ränder lassen sich nachziehen; Rechtsklick in den Bereich = Menü (schneiden, Schnitt, Loop); Klick daneben hebt ihn auf.
/// EDIT-Modus: Ziehen markiert ohne Taste (Raster der Edit-Zeile), Klick setzt eine Schnittmarke (nächster Beat),
/// Doppelklick wählt das Stück, Marken lassen sich ziehen, Rechtsklick = Menü der Schnittliste
struct WaveMouse: NSViewRepresentable {
    let mix: MixModel
    let d: Int
    let scene: WaveScene

    func makeNSView(context: Context) -> WaveMouseView { WaveMouseView() }

    func updateNSView(_ v: WaveMouseView, context: Context) {
        v.mix = mix
        v.d = d
        v.scene = scene
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveMouseView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class WaveMouseView: NSView {
    weak var mix: MixModel?
    var d = 0
    var scene = WaveScene()

    /// Scrub (letztes x), Griff des Schnitts, Bereich vom festen Rand aus (`fresh` = neu markiert, nicht nachgezogen),
    /// Naht der Schnittliste, Wellenform greifen (Stand in `grab…`)
    private enum Drag { case scrub(CGFloat), trim(end: Bool), mark(anchor: Double, fresh: Bool), joint(Int), grab }
    private var drag: Drag?
    private var downX: CGFloat = 0
    private var moved = false
    /// Zeiger: Pfeil, Horizontal-Doppelpfeil (Rand, Naht, Griff des Schnitts), offene Hand (greifbar), geschlossene Hand
    private enum Pointer { case arrow, resize, open, closed }
    private var pointer = Pointer.arrow
    private var tracking: NSTrackingArea?
    /// Greifen: letztes x, Ziel der Hand in Sekunden (Vinyl; nil bis zur ersten Bewegung), geglättete Vorwärts-Geschwindigkeit
    /// (Jog), Zeit des letzten Zugs, ob der Bend des Decks an ist, Zeitgeber, der den Bend nach dem Stillstand auslaufen lässt
    private var grabLast: CGFloat = 0
    private var grabTarget: Double?
    private var grabSpeed = 0.0
    private var grabStamp: TimeInterval = 0
    private var grabBending = false
    private var grabTimer: Timer?
    /// Klick im EDIT-Modus: Marke erst nach der Doppelklick-Zeit (ein Doppelklick wählt stattdessen das Stück)
    private var pendingMark: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var secPerPt: Double { scene.span * 2 / Double(max(1, bounds.width)) }
    private func time(_ x: CGFloat, _ mix: MixModel) -> Double { mix.position(d) + Double(x - bounds.width / 2) * secPerPt }
    private func xOf(_ t: Double, _ mix: MixModel) -> CGFloat { CGFloat((t - mix.position(d)) / secPerPt) + bounds.width / 2 }
    private func point(_ e: NSEvent) -> CGFloat { convert(e.locationInWindow, from: nil).x }
    private var editing: Bool { scene.edit != nil }
    private func snap(_ t: Double, _ e: NSEvent) -> Double {
        if editing, let mix {
            return TrackRange.snap(t, grid: scene.grid, step: mix.prefs.ui.editSnap.beats, free: e.modifierFlags.contains(.option), duration: scene.duration)
        }
        return TrackRange.snap(t, grid: scene.grid, free: e.modifierFlags.contains(.option), duration: scene.duration)
    }
    /// Marken: nächster Beat (⌥ = frei)
    private func snapBeat(_ t: Double, _ e: NSEvent) -> Double {
        TrackRange.snap(t, grid: scene.grid, step: 1, free: e.modifierFlags.contains(.option), duration: scene.duration)
    }

    /// Rand des Bereichs unter x (false = Anfang, true = Ende), höchstens 6 pt entfernt
    private func edge(at x: CGFloat, _ mix: MixModel) -> Bool? {
        guard let r = mix.range(d) else { return nil }
        let a = abs(xOf(r.start, mix) - x), b = abs(xOf(r.end, mix) - x)
        guard min(a, b) <= 6 * scene.zoom else { return nil }
        return b < a
    }

    /// Greifen der Wellenform: Einstellung an, Deck mit Track, nicht im EDIT-Modus, ohne Taste (⌃ / ⌥ und die übrigen
    /// behalten ihre Bedeutung)
    private func grabbable(_ e: NSEvent, _ mix: MixModel) -> Bool {
        mix.prefs.ui.waveGrab != .off && !mix.editing(d) && scene.hasTrack && scene.duration > 0
            && e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// Naht der Schnittliste unter x, höchstens 6 pt entfernt
    private func joint(at x: CGFloat, _ mix: MixModel) -> Int? {
        guard let e = scene.edit, !e.joints.isEmpty else { return nil }
        let dist = e.joints.map { abs(xOf($0, mix) - x) }
        guard let k = dist.indices.min(by: { dist[$0] < dist[$1] }), dist[k] <= 6 * scene.zoom else { return nil }
        return k
    }

    override func mouseDown(with e: NSEvent) {
        guard let mix else { return }
        if mix.focusedDeck != d { mix.focusedDeck = d }
        let x = point(e)
        downX = x
        moved = false
        pendingMark?.cancel()
        pendingMark = nil
        grabTimer?.invalidate()
        grabTimer = nil
        guard scene.hasTrack, scene.duration > 0, bounds.width > 0 else { drag = nil; return }
        if editing, e.clickCount == 2 {
            mix.editSelectSegment(d, at: time(x, mix))
            drag = nil
            return
        }
        if let end = edge(at: x, mix), let r = mix.range(d) {
            drag = .mark(anchor: end ? r.start : r.end, fresh: false)
        } else if editing, let k = joint(at: x, mix) {
            drag = .joint(k)
        } else if !e.modifierFlags.contains(.control),
                  let h = WaveformView.trimHandle(at: x, width: bounds.width, scene: scene, position: mix.position(d)) {
            drag = .trim(end: h == 1)
        } else if editing || e.modifierFlags.contains(.control) {
            drag = .mark(anchor: snap(time(x, mix), e), fresh: true)
        } else if grabbable(e, mix) {
            drag = .grab
            grabLast = x
            grabTarget = nil
            grabSpeed = 0
            grabBending = false
            grabStamp = ProcessInfo.processInfo.systemUptime
            pointer = .closed
            NSCursor.closedHand.set()
            if mix.prefs.ui.waveGrab == .jog {
                grabTimer = Timer.scheduledTimer(timeInterval: 1.0 / 30, target: self, selector: #selector(grabIdle), userInfo: nil, repeats: true)
            }
        } else {
            drag = .scrub(x)
        }
    }

    /// Greifen: ein Zug um das letzte x. Vinyl: die Hand legt das Ziel fest, der Kern läuft nach (Scratch), im Stopp auch.
    /// Jog: läuft das Deck, Pitch-Bend nach der Hand-Geschwindigkeit; steht es, suchen wie bisher.
    private func grabMove(_ x: CGFloat, _ mix: MixModel) {
        let now = ProcessInfo.processInfo.systemUptime
        let dragPx = Double(x - grabLast), dt = now - grabStamp
        grabLast = x
        grabStamp = now
        let w = Double(bounds.width)
        switch mix.prefs.ui.waveGrab {
        case .vinyl:
            let t = (grabTarget ?? mix.position(d)) + WaveGrabMath.seconds(dragPx: dragPx, span: scene.span, width: w)
            grabTarget = t
            mix.scratch(d, to: t, held: true)
        case .jog where mix.deck(d).playing:
            grabSpeed = 0.5 * grabSpeed + 0.5 * WaveGrabMath.speed(dragPx: dragPx, dt: dt, span: scene.span, width: w)
            if !grabBending { grabBending = true; mix.grab(d, true) }
            mix.grabBend(d, WaveGrabMath.bend(speed: grabSpeed))
        default:
            if grabBending { grabBending = false; mix.grabBend(d, 0); mix.grab(d, false) }
            // eigenes Ziel wie bei Vinyl: die gemeldete Position hängt beim Suchen nach, Schritte darauf summierten den Fehler
            let t = (grabTarget ?? mix.position(d)) + WaveGrabMath.seconds(dragPx: dragPx, span: scene.span, width: w)
            grabTarget = t
            mix.scrub(d, seconds: t)
        }
    }

    /// Hand steht still: der Bend läuft aus (ohne neuen Zug bliebe der letzte Wert stehen)
    @objc private func grabIdle() {
        guard grabBending, let mix, ProcessInfo.processInfo.systemUptime - grabStamp > 0.05 else { return }
        grabSpeed *= 0.5
        if abs(grabSpeed) < 0.01 { grabSpeed = 0 }
        mix.grabBend(d, WaveGrabMath.bend(speed: grabSpeed))
    }

    override func mouseDragged(with e: NSEvent) {
        guard let mix, let drag else { return }
        let x = point(e)
        if abs(x - downX) >= 1 { moved = true }
        guard moved else { return }
        switch drag {
        case let .scrub(last):
            mix.scrub(d, seconds: mix.position(d) - Double(x - last) * secPerPt)
            self.drag = .scrub(x)
        case let .trim(end):
            mix.dragTrim(d, end: end, to: time(x, mix))
        case let .mark(anchor, fresh):
            if fresh { mix.dropRipMark(d) }   // neue Markierung: kein RIP-Bereich mehr
            let t = snap(time(x, mix), e)
            mix.setRange(d, abs(t - anchor) < 1e-6 ? nil : TrackRange(anchor, t))
        case let .joint(k):
            mix.editShowJoint(d, k, at: snapBeat(time(x, mix), e))
        case .grab:
            grabMove(x, mix)
        }
    }

    override func mouseUp(with e: NSEvent) {
        guard let mix else { return }
        defer { drag = nil }
        grabTimer?.invalidate()
        grabTimer = nil
        switch drag {
        case let .mark(_, fresh) where fresh && !moved:
            if editing {
                // Klick: Bereich da -> daneben hebt ihn auf; sonst Schnittmarke am nächsten Beat
                let t = time(point(e), mix)
                if let r = mix.range(d) {
                    if !(r.start...r.end).contains(t) { mix.setRange(d, nil) }
                    return
                }
                let at = snapBeat(t, e), deck = d
                let w = DispatchWorkItem { [weak self, weak mix] in
                    self?.pendingMark = nil
                    mix?.editMark(deck, at: at)
                }
                pendingMark = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.markDelay, execute: w)
            } else {
                mix.setRange(d, nil)   // ⌃-Klick ohne Ziehen: Markierung weg
            }
        case let .joint(k):
            if moved { mix.editMoveJoint(d, k, to: snapBeat(time(point(e), mix), e)) }
        case .scrub where !moved, .grab where !moved:
            if let r = mix.range(d), !(r.start...r.end).contains(time(point(e), mix)) { mix.setRange(d, nil) }   // Klick daneben
        case .grab:
            // losgelassen: der Kern läuft aufs Ziel aus (Vinyl) bzw. der Bend läuft aus (Jog)
            if let t = grabTarget { mix.scratch(d, to: t, held: false) }
            if grabBending { grabBending = false; mix.grabBend(d, 0); mix.grab(d, false) }
        default: break
        }
        updatePointer(e)
    }

    /// Wartezeit vor einer Marke (Doppelklick-Zeit des Systems, höchstens 0,35 s)
    static var markDelay: Double { min(0.35, NSEvent.doubleClickInterval) }

    /// Rechtsklick (nicht ⌃-Klick) in den Bereich: Menü; im EDIT-Modus überall das Menü der Schnittliste. Oben „Track ▸“
    /// mit dem Track-Menü des Decks; ohne eigenes Menü gleich das Track-Menü
    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown, let mix else { return nil }
        let track = enclosingAreaMenu(for: event)
        guard let m = waveMenu(event, mix) else { return track }
        if let track {
            let i = NSMenuItem(title: String(localized: "Track"), action: nil, keyEquivalent: "")
            i.submenu = track
            m.insertItem(i, at: 0)
            m.insertItem(.separator(), at: 1)
        }
        return m
    }

    private func waveMenu(_ event: NSEvent, _ mix: MixModel) -> NSMenu? {
        let t = time(point(event), mix)
        if editing {
            if mix.focusedDeck != d { mix.focusedDeck = d }
            return EditMenu.make(mix: mix, d: d, at: t, joint: joint(at: point(event), mix),
                                 label: mix.rangeMarked(d, grid: scene.grid)?.label, inRange: mix.range(d).map { t >= $0.start && t <= $0.end } ?? false)
        }
        guard let r = mix.range(d) else { return nil }
        guard t >= r.start, t <= r.end else { return nil }
        if mix.focusedDeck != d { mix.focusedDeck = d }
        return WaveRangeMenu.make(mix: mix, d: d, label: mix.rangeMarked(d, grid: scene.grid)?.label ?? "")
    }

    // Zeiger: über einem Rand des Bereichs, einer Naht oder einem Griff des Schnitts ↔, sonst offene Hand, wo sich greifen lässt
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with e: NSEvent) { updatePointer(e) }

    private func updatePointer(_ e: NSEvent) {
        guard let mix else { return }
        let x = point(e)
        let resize = edge(at: x, mix) != nil || joint(at: x, mix) != nil
            || WaveformView.trimHandle(at: x, width: bounds.width, scene: scene, position: mix.position(d)) != nil
        let p: Pointer = resize ? .resize : grabbable(e, mix) ? .open : .arrow
        guard p != pointer else { return }
        pointer = p
        switch p {
        case .arrow: NSCursor.arrow.set()
        case .resize: NSCursor.resizeLeftRight.set()
        case .open: NSCursor.openHand.set()
        case .closed: NSCursor.closedHand.set()
        }
    }

    override func mouseExited(with e: NSEvent) {
        if pointer != .arrow { pointer = .arrow; NSCursor.arrow.set() }
    }
}

/// Menü zum markierten Bereich (Rechtsklick in der Wellenform)
@MainActor
enum WaveRangeMenu {
    static func make(mix: MixModel, d: Int, label: String) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let head = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        ripReason(m, mix: mix, d: d)
        m.addItem(.separator())
        markedRemove(m, mix: mix, d: d)
        m.addItem(.separator())
        m.addItem(ActionItem(String(localized: "Auf Bereich kürzen (neue Datei)")) { mix.cutRange(d, mode: .keep) })
        let load = ActionItem(String(localized: "Ergebnis ins Deck laden")) { mix.prefs.ui.cutLoadsResult.toggle() }
        load.state = mix.prefs.ui.cutLoadsResult ? .on : .off
        m.addItem(load)
        m.addItem(.separator())
        m.addItem(ActionItem(String(localized: "Schnitt IN/OUT aus Bereich")) { mix.rangeToTrim(d) })
        m.addItem(ActionItem(String(localized: "Loop aus Bereich")) { mix.rangeToLoop(d) })
        m.addItem(.separator())
        m.addItem(ActionItem(String(localized: "Bereich aufheben")) { mix.clearRange(d) })
        ripDismiss(m, mix: mix, d: d)
        return m
    }

    /// RIP-Bereich: Grund unter der Beschriftung
    static func ripReason(_ m: NSMenu, mix: MixModel, d: Int) {
        guard let r = mix.ripMark(d) else { return }
        let i = NSMenuItem(title: RipChecks.text(r.finding) + " – " + RipChecks.reasons(r.finding), action: nil, keyEquivalent: "")
        i.isEnabled = false
        m.addItem(i)
    }

    /// „Markierten Bereich entfernen“ (Schnittliste) und „… (neue Datei)“ – die neue Datei nur, solange das Deck das
    /// Original spielt
    static func markedRemove(_ m: NSMenu, mix: MixModel, d: Int) {
        m.addItem(ActionItem(String(localized: "Markierten Bereich entfernen")) { mix.removeMarkedRange(d) })
        let file = ActionItem(String(localized: "Markierten Bereich entfernen (neue Datei)")) { mix.cutRange(d, mode: .remove) }
        file.isEnabled = mix.playedEditList(d) == nil
        m.addItem(file)
    }

    /// RIP-Bereich: Befund verwerfen (Bereich bleibt markiert)
    static func ripDismiss(_ m: NSMenu, mix: MixModel, d: Int) {
        guard let r = mix.ripMark(d) else { return }
        m.addItem(ActionItem(String(localized: "Befund verwerfen")) { RipChecks.shared.dismiss(r.key, [r.finding]) })
    }
}

/// Menü der Schnittliste (Rechtsklick in der Wellenform im EDIT-Modus): alle Aktionen, auch die, für die eine schmale
/// Edit-Zeile keinen Platz hat
@MainActor
enum EditMenu {
    static func make(mix: MixModel, d: Int, at t: Double, joint: Int?, label: String?, inRange: Bool = false) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let session = mix.editSession(d)
        if let label {
            let head = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            head.isEnabled = false
            m.addItem(head)
            WaveRangeMenu.ripReason(m, mix: mix, d: d)
            m.addItem(.separator())
        }
        if inRange {
            WaveRangeMenu.markedRemove(m, mix: mix, d: d)
            m.addItem(.separator())
        }
        for op in EditOp.allCases {
            let i = ActionItem(op.label) { mix.editAction(d, op) }
            i.isEnabled = session != nil
            m.addItem(i)
        }
        m.addItem(.separator())
        let snapped = TrackRange.snap(t, grid: mix.deck(d).grid, step: 1, free: false, duration: mix.deck(d).duration)
        m.addItem(ActionItem(String(localized: "Schnittmarke hier")) { mix.editMark(d, at: snapped) })
        if let k = joint {
            m.addItem(ActionItem(String(localized: "Schnittmarke entfernen")) { mix.editRemoveMark(d, k) })
        }
        m.addItem(ActionItem(String(localized: "Segment auswählen")) { mix.editSelectSegment(d, at: t) })
        let snap = NSMenuItem(title: String(localized: "Raster"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in EditSnap.allCases {
            let i = ActionItem(v.label) { mix.setEditSnap(v) }
            i.state = mix.prefs.ui.editSnap == v ? .on : .off
            sub.addItem(i)
        }
        snap.submenu = sub
        m.addItem(snap)
        m.addItem(.separator())
        let render = ActionItem(String(localized: "Rendern (neue Datei)")) { mix.editRenderFile(d) }
        render.isEnabled = !(session?.shown.isPlain ?? true)
        m.addItem(render)
        let load = ActionItem(String(localized: "Ergebnis ins Deck laden")) { mix.prefs.ui.cutLoadsResult.toggle() }
        load.state = mix.prefs.ui.cutLoadsResult ? .on : .off
        m.addItem(load)
        let reset = ActionItem(String(localized: "Schnittliste verwerfen")) { mix.editReset(d) }
        reset.isEnabled = (session?.shown.segments.count ?? 1) > 1
        m.addItem(reset)
        m.addItem(.separator())
        let tl = NSMenuItem(title: String(localized: "Tool-Loop exportieren"), action: nil, keyEquivalent: "")
        let tsub = NSMenu()
        for b in ToolLoop.sizes { tsub.addItem(ActionItem(String(localized: "\(b) Beats")) { mix.exportToolLoop(d, beats: b) }) }
        tl.submenu = tsub
        m.addItem(tl)
        m.addItem(.separator())
        if !(session?.preview != nil) {
            m.addItem(ActionItem(String(localized: "Schnitt-Anfang hier")) { mix.trimHere(d, end: false) })
            m.addItem(ActionItem(String(localized: "Schnitt-Ende hier")) { mix.trimHere(d, end: true) })
            m.addItem(ActionItem(String(localized: "Schnitt entfernen")) { mix.clearTrim(d) })
        }
        if mix.range(d) != nil {
            m.addItem(ActionItem(String(localized: "Loop aus Bereich")) { mix.rangeToLoop(d) })
            m.addItem(ActionItem(String(localized: "Bereich aufheben")) { mix.clearRange(d) })
            WaveRangeMenu.ripDismiss(m, mix: mix, d: d)
        }
        return m
    }
}

/// Track-Übersicht: ganze Wellenform, gespielter Teil gedimmt, Cues, Loop; Klick springt.
struct OverviewView: View {
    @Environment(MixModel.self) private var mix
    @Environment(WaveformCache.self) private var cache
    let d: Int

    struct Model: Equatable {
        var duration = 0.0, playing = false
        var cues: [WaveScene.Mark] = []
        var trim = WaveScene.Trim()
        var range: TrackRange?
        /// offene Befunde der Rip-Prüfung (gestreift)
        var rip: [ClosedRange<Double>] = []
        /// Loop im Kern ist der Auto-Loop vom Laden (auch inaktiv gezeigt)
        var autoLoop = false
    }

    var body: some View {
        let ui = mix.prefs.ui
        let deck = mix.deck(d)
        let wf = cache.waveform(for: mix.audio(d), ui: ui, preset: mix.wavePreset)
        let cues = deck.hotcues.values.map {
            WaveScene.Mark(t: $0.startMs / 1000, number: $0.hotcue + 1, color: NSColor(Theme.cueColor($0, deck: deck, prefs: mix.prefs)))
        }
        Content(d: d, m: Model(duration: deck.duration, playing: deck.playing, cues: cues,
                               trim: .init(start: deck.trim.start, end: deck.trim.end, editing: mix.editing(d) && !(mix.decks[d].edit?.previewing ?? false)), range: mix.range(d),
                               rip: RipChecks.shared.revision >= 0 ? RipChecks.shared.regions(deck.track?.key ?? "", duration: deck.duration) : [],
                               autoLoop: deck.autoLoop),
                wave: wf).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        let wave: RenderedWaveform?
        /// gezogener Griff des Schnitts (EDIT-Modus), sonst springt der Klick
        @State private var handle: Int?
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m && a.wave === b.wave }

        /// Griff unter x (0 = Anfang, 1 = Ende), höchstens 6 pt entfernt
        private func grip(at x: CGFloat, width: CGFloat) -> Int? {
            guard m.trim.editing, m.duration > 0, width > 0 else { return nil }
            let xs = [m.trim.start ?? 0, m.trim.end ?? m.duration].map { CGFloat($0 / m.duration) * width }
            let dist = xs.map { abs($0 - x) }
            guard let i = dist.indices.min(by: { dist[$0] < dist[$1] }), dist[i] <= 6.z else { return nil }
            return i
        }

        var body: some View {
            let m = m, wf = wave
            GeometryReader { geo in
                LiveCanvas(fps: m.playing ? 15 : 4, running: m.duration > 0) { [mix, d] ctx, size in
                    ctx.setFillColor(CG.wave); ctx.fill(CGRect(origin: .zero, size: size))
                    guard m.duration > 0 else { return }
                    if let img = wf?.overview { ctx.draw(img, in: CGRect(origin: .zero, size: size)) }
                    let f = mix.position(d) / m.duration
                    ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: size.width * f, height: size.height))
                    let loop = mix.engine.loop(d)
                    if loop.active || m.autoLoop && loop.end > loop.start {
                        ctx.setFillColor((loop.active ? NSColor(Theme.state).withAlphaComponent(0.4) : NSColor(Theme.bone).withAlphaComponent(0.25)).cgColor)
                        ctx.fill(CGRect(x: loop.start / m.duration * size.width, y: 0,
                                        width: max(2, (loop.end - loop.start) / m.duration * size.width), height: size.height))
                    }
                    for r in m.rip {   // offener Rip-Befund: gestreift wie der markierte Bereich
                        let x0 = r.lowerBound / m.duration * size.width, w = max(2, (r.upperBound - r.lowerBound) / m.duration * size.width)
                        let box = CGRect(x: x0, y: 0, width: w, height: size.height)
                        ctx.saveGState()
                        ctx.clip(to: box)
                        ctx.setFillColor(NSColor(Theme.state).withAlphaComponent(0.12).cgColor)
                        ctx.fill(box)
                        ctx.setStrokeColor(NSColor(Theme.state).withAlphaComponent(0.55).cgColor)
                        ctx.setLineWidth(1)
                        var x = x0 - size.height
                        while x < x0 + w {
                            ctx.move(to: CGPoint(x: x, y: size.height)); ctx.addLine(to: CGPoint(x: x + size.height, y: 0))
                            x += 6
                        }
                        ctx.strokePath()
                        ctx.restoreGState()
                    }
                    if let r = m.range {   // markierter Bereich
                        ctx.setFillColor(NSColor(Theme.state).withAlphaComponent(0.35).cgColor)
                        ctx.fill(CGRect(x: r.start / m.duration * size.width, y: 0,
                                        width: max(2, r.length / m.duration * size.width), height: size.height))
                    }
                    for c in m.cues {
                        ctx.setFillColor(c.color.cgColor)
                        ctx.fill(CGRect(x: c.t / m.duration * size.width, y: 0, width: 2, height: size.height))
                    }
                    // Schnitt: davor / dahinter gedimmt, im EDIT-Modus Griffe
                    let t = m.trim
                    if t.start != nil || t.end != nil || t.editing {
                        let x0 = CGFloat((t.start ?? 0) / m.duration) * size.width, x1 = CGFloat((t.end ?? m.duration) / m.duration) * size.width
                        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
                        if t.start != nil { ctx.fill(CGRect(x: 0, y: 0, width: x0, height: size.height)) }
                        if t.end != nil { ctx.fill(CGRect(x: x1, y: 0, width: size.width - x1, height: size.height)) }
                        ctx.setFillColor(t.editing ? CG.bone : NSColor(Theme.bone).withAlphaComponent(0.6).cgColor)
                        let lw: CGFloat = t.editing ? 2 : 1, tab = 4 * size.height / 18
                        for (x, set, dir) in [(x0, t.start != nil, CGFloat(-1)), (x1, t.end != nil, CGFloat(1))] where set || t.editing {
                            let lx = min(max(0, x - lw / 2), size.width - lw)
                            ctx.fill(CGRect(x: lx, y: 0, width: lw, height: size.height))
                            if t.editing {   // Griff-Laschen oben und unten, nach außen
                                ctx.fill(CGRect(x: dir < 0 ? lx - tab : lx, y: 0, width: tab + lw, height: tab))
                                ctx.fill(CGRect(x: dir < 0 ? lx - tab : lx, y: size.height - tab, width: tab + lw, height: tab))
                            }
                        }
                    }
                    ctx.setFillColor(CG.state)
                    ctx.fill(CGRect(x: size.width * f - 1, y: 0, width: 2, height: size.height))
                }
                .clipShape(Rectangle())
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let w = geo.size.width
                        if handle == nil { handle = grip(at: v.startLocation.x, width: w).map { $0 + 1 } ?? 0 }
                        if let h = handle, h > 0 {   // 1 = Anfang, 2 = Ende; 0 = springen
                            mix.dragTrim(d, end: h == 2, to: max(0, min(1, v.location.x / w)) * m.duration)
                        } else {
                            mix.seek(d, fraction: v.location.x / w)
                        }
                    }
                    .onEnded { _ in handle = nil })
            }
        }
    }
}

/// − / + unten rechts in der Wellenform: sichtbare Sekunden je Seite in festen Stufen (alle Decks gleich,
/// Beat-Abstände bleiben zwischen den Decks vergleichbar)
struct WaveZoomButtons: View {
    @Environment(MixModel.self) private var mix
    static let steps: [Double] = [1, 1.5, 2, 3, 4, 6, 8, 12, 16]

    /// nächste Stufe: rein = weniger Sekunden, raus = mehr
    static func next(_ cur: Double, zoomIn: Bool) -> Double {
        zoomIn ? steps.last { $0 < cur - 1e-9 } ?? steps[0] : steps.first { $0 > cur + 1e-9 } ?? steps[steps.count - 1]
    }

    var body: some View {
        let cur = mix.prefs.ui.waveformSeconds
        HStack(spacing: 1.z) {
            cell("−", enabled: cur < Self.steps.last! - 1e-9) { mix.prefs.ui.waveformSeconds = Self.next(cur, zoomIn: false) }
                .help("Wellenform verkleinern (mehr Sekunden)")
            cell("+", enabled: cur > Self.steps[0] + 1e-9) { mix.prefs.ui.waveformSeconds = Self.next(cur, zoomIn: true) }
                .help("Wellenform vergrößern (weniger Sekunden)")
        }
    }

    private func cell(_ t: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: t).font(Theme.mono(11.z, .semibold))
                .frame(width: 14.z, height: 13.z)
                .foregroundStyle(enabled ? Theme.bone : Theme.muted)
                .background(Theme.void.opacity(0.75))
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
