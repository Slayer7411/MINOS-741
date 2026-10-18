import Foundation

/// LIVE-Absturzschutz: VST3-Plugins laufen im Prozess von MINOS-741 und können bei einem Fehler die ganze App mitreißen.
/// Bei LIVE (und eingeschalteter Einstellung) bleibt ihr Slot trocken, das Plugin rechnet nicht. Audio Units laufen
/// ohnehin im eigenen Dienst, eingebaute Effekte bleiben aktiv.
public enum LiveBypass {
    /// Slot überbrückt? `vst3InProcess`: der Slot hält eine VST3-Instanz (laufen immer im Prozess)
    public static func bypassed(live: Bool, enabled: Bool, vst3InProcess: Bool) -> Bool {
        live && enabled && vst3InProcess
    }

    /// Slot-Schalter, wie er an den Kern geht: eingeschaltet und nicht überbrückt. Der Kern blendet die Änderung
    /// über den D/W-Gleichlauf des Slots aus bzw. ein
    public static func effectiveOn(_ on: Bool, bypassed: Bool) -> Bool {
        on && !bypassed
    }
}
