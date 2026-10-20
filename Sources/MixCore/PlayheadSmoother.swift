import Foundation

/// Spielkopf für die Anzeige. Der Audiokern meldet die Position einmal je Block (512 Frames ≈ 10.7 ms bei 48 kHz);
/// bei 60 / 120 Hz rückt die Wellenform sonst je Bild um 0, 1 oder 2 Blöcke vor (ungleichmäßig, wirkt wie Ruckeln).
/// Hier läuft die Anzeige mit der Abspielgeschwindigkeit weiter und wird sanft zur gemeldeten Position gezogen.
/// Stehendes Deck, Sprünge (Seek, Beatjump, Loop, Hotcue) und ausbleibende Meldungen -> genau die gemeldete Position.
public struct PlayheadSmoother: Sendable {
    /// Anteil des Fehlers, der je Bild ausgeglichen wird
    public var pull = 0.1
    /// angezeigte Position (s), nan vor dem ersten Aufruf
    public private(set) var shown = Double.nan
    private var raw = Double.nan
    private var lastFrame = Double.nan
    private var lastChange = 0.0
    private var lastSpeed = 0.0
    /// Abstand zwischen zwei Meldungen, wie ihn die Bilder sehen (größter, langsam fallend)
    public private(set) var gap = 0.02

    public init() {}

    /// raw = gemeldete Position (s) · speed = Abspielgeschwindigkeit (s je s, 0 = steht, negativ = rückwärts) · t = Bildzeit (s)
    public mutating func update(raw r: Double, speed v: Double, at t: Double) -> Double {
        let dt = t - lastFrame, started = lastSpeed == 0
        lastFrame = t
        lastSpeed = v
        observe(r, at: t)
        // steht, läuft gerade an, erster Aufruf, Bildzeit springt, keine Meldung seit zwei Abständen (Stopp, Trackende):
        // gemeldete Position
        guard v != 0, !started, !shown.isNaN, dt > 0, dt < 0.1, t - lastChange <= 2 * gap + 0.002 else { shown = r; return r }
        var p = shown + v * dt
        let lead = abs(v) * (gap + dt)   // so weit kann die hörbare Position der letzten Meldung voraus sein
        let e = (r - p) * (v > 0 ? 1 : -1)   // + = Meldung liegt in Laufrichtung vorn
        if e < -lead || e > 2 * lead { shown = r; return r }   // Sprung
        p += (r - p) * pull
        // höchstens einen Meldeabstand vor der Meldung: beim Stoppen läuft die Anzeige kaum über
        p = v > 0 ? min(p, r + lead) : max(p, r - lead)
        shown = p
        return p
    }

    /// Mit Stempel: `heard` = Zeit (s), zu der `r` hörbar ist (Blockende + Ausgabelatenz). Die Anzeige ist dann
    /// r + v·(t − heard), unabhängig davon, wie alt der letzte Block beim Bild ist: kein Nachziehen, keine Rückführung.
    /// Die Rückführung auf die gemeldete Position bleibt für Stillstand und Ausfall (keine Meldung seit zwei Abständen).
    public mutating func update(raw r: Double, speed v: Double, at t: Double, heard: Double) -> Double {
        lastFrame = t
        lastSpeed = v
        observe(r, at: t)
        guard v != 0, !heard.isNaN, t - lastChange <= 2 * gap + 0.002 else { shown = r; return r }
        shown = r + v * (t - heard)
        return shown
    }

    /// Meldeabstand und Zeitpunkt der letzten Änderung der gemeldeten Position
    private mutating func observe(_ r: Double, at t: Double) {
        guard r != raw else { return }
        let g = t - lastChange
        if g > 0, g < 0.1 { gap = g > gap ? g : gap + (g - gap) * 0.02 }
        raw = r
        lastChange = t
    }
}
