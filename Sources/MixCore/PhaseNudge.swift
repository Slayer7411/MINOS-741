import Foundation

/// Phasen-Nachzug eines synchronisierten Decks: der Phasenfehler (Beat) wird geglättet, bevor er in eine
/// Rate-Abweichung umgesetzt wird. Eintritt und Austritt sind getrennt (Hysterese), damit ein Fehler um die
/// Nullstelle die Rate nicht bei jedem Block umschaltet.
public struct PhaseNudge: Sendable {
    /// Eintritt ab diesem Fehler (Beat), Austritt unter `leave`
    public static let enter = 0.004, leave = 0.002
    /// Verstärkung und Begrenzung der Rate-Abweichung (Anteil)
    public static let gain = 0.6, limit = 0.06
    /// Zeitkonstante der Glättung (s)
    public static let tau = 0.075

    public private(set) var smoothed = 0.0
    public private(set) var active = false

    public init() {}

    public mutating func reset() { smoothed = 0; active = false }

    /// `error`: Phasenfehler (Beat), `dt`: Zeit seit dem letzten Schritt (s). Liefert die Rate-Abweichung (Anteil).
    public mutating func update(error: Double, dt: Double) -> Double {
        smoothed += (error - smoothed) * (1 - exp(-max(0, dt) / Self.tau))
        let m = abs(smoothed)
        if active { if m < Self.leave { active = false } } else if m >= Self.enter { active = true }
        return active ? max(-Self.limit, min(Self.limit, -smoothed * Self.gain)) : 0
    }
}
