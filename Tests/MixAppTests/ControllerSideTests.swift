import Foundation
import Testing
import MixCore
@testable import MixEngine
@testable import MixApp

// Feste Seite je Controller (Seriennummer, sonst USB-Position) und Startsequenz – ohne Gerät.

@Test func controllerSideKeyFallsBackToLocation() {
    #expect(ControllerSides.key(serial: " ABC123 ", location: 0x1420_0000) == "ABC123")
    #expect(ControllerSides.key(serial: "", location: 0x1420_0000) == "loc-14200000")
    #expect(ControllerSides.key(serial: nil, location: 0) == nil)
    #expect(!ControllerSides.isStable(ControllerSides.tempPrefix + "x") && ControllerSides.isStable("loc-14200000"))
}

@Test func controllerSideResolveInOrderSavedAndConflict() {
    // ohne Eintrag: der Reihe nach
    #expect(ControllerSides.resolve(saved: nil, taken: [])! == (.left, false))
    #expect(ControllerSides.resolve(saved: nil, taken: [.left])! == (.right, false))
    // gespeichert und frei: bleibt, auch als erstes Gerät
    #expect(ControllerSides.resolve(saved: .right, taken: [])! == (.right, false))
    // Konflikt: das zweite Gerät bekommt die andere Seite
    #expect(ControllerSides.resolve(saved: .left, taken: [.left])! == (.right, true))
    // dritter Controller: keine Seite
    #expect(ControllerSides.resolve(saved: .left, taken: [.left, .right]) == nil)
    // alte Deck-Zuordnung
    #expect(ControllerSide(decks: 0, 2) == .left && ControllerSide(decks: 1, 3) == .right && ControllerSide(decks: 0, 1) == nil)
    #expect(ControllerSides.saved("SN", in: ["SN": "right", "X": "oben"]) == .right && ControllerSides.saved("X", in: ["X": "oben"]) == nil)
}

@Test func controllerSideAssignSwapsTheOther() {
    let cur: [String: ControllerSide] = ["L": .left, "R": .right]
    #expect(ControllerSides.assign("R", to: .left, current: cur) == ["L": .right, "R": .left])
    #expect(ControllerSides.assign("L", to: .left, current: cur) == cur)
    #expect(ControllerSides.assign("L", to: .right, current: ["L": .left]) == ["L": .right])
}

@MainActor @Test func controllerManagerStoresSidesAndSwaps() {
    let core = testController()
    let manager = ControllerManager(core: core, status: ControllerStatus())
    let a = "TEST-A-\(UUID().uuidString)", b = "TEST-B-\(UUID().uuidString)"
    defer { for k in [a, b] { for p in ["x1.", "x1pane.", "x1fx."] { UserDefaults.standard.removeObject(forKey: p + k) } } }
    // B steht gespeichert links, kommt aber als zweiter: A (neu) bekommt links, B weicht nach rechts aus
    var p = ControllerPrefs()
    p.sides = [b: "left"]
    manager.prefs = p
    let ia = manager.register(device: nil, serial: a, location: 1, name: "T")
    let ib = manager.register(device: nil, serial: b, location: 2, name: "T")
    #expect(ia?.side == .left && ia?.left == 0 && ia?.right == 2 && ia?.pane == 0 && ia?.fxUnit == 10)
    #expect(ib?.side == .right && ib?.left == 1 && ib?.right == 3 && ib?.pane == 1 && ib?.fxUnit == 11)
    #expect(manager.storedSide(a) == .left && manager.storedSide(b) == .right)
    // gleiches Gerät noch einmal: nichts doppelt
    #expect(manager.register(device: nil, serial: a, location: 1, name: "T") == nil)

    // Tausch per Seite: A nach rechts, B wechselt nach links, Decks hängen um
    manager.setSide(a, .right)
    core.controlQueue.sync {}
    let ua = manager.unit(a)!.info, ub = manager.unit(b)!.info
    #expect(ua.side == .right && ua.left == 1 && ua.right == 3)
    #expect(ub.side == .left && ub.left == 0 && ub.right == 2)
    #expect(manager.storedSide(a) == .right && manager.storedSide(b) == .left)
}

@MainActor @Test func controllerManagerKeepsOwnDecksOnItsSide() {
    let core = testController()
    let manager = ControllerManager(core: core, status: ControllerStatus())
    let a = "TEST-C-\(UUID().uuidString)"
    defer { for p in ["x1.", "x1pane.", "x1fx."] { UserDefaults.standard.removeObject(forKey: p + a) } }
    // alte Zuordnung B/D ohne gespeicherte Seite -> rechts, Decks bleiben
    UserDefaults.standard.set([1, 3], forKey: "x1.\(a)")
    let i = manager.register(device: nil, serial: "", location: 0, name: "T")   // ohne Kennung: wird nicht gespeichert
    #expect(i?.side == .left && i.map { ControllerSides.isStable($0.id) } == false && manager.storedSide(i!.id) == nil)
    let j = manager.register(device: nil, serial: a, location: 3, name: "T")
    #expect(j?.side == .right && j?.left == 1 && j?.right == 3)
}

// MARK: - Startsequenz

/// alle Gruppen im normalen Zustand (nil)
private func allNormal(_ f: LEDShow.Frame) -> Bool {
    f.pads.allSatisfy { $0 == nil } && f.buttons.allSatisfy { $0 == nil }
        && f.digits.allSatisfy { $0 == nil } && f.strip.allSatisfy { $0 == nil }
}

/// leuchtende LEDs, die noch nicht im normalen Zustand sind
private func shownLEDs(_ f: LEDShow.Frame) -> Int {
    f.pads.reduce(0) { $0 + (($1?.level ?? 0) > 0 ? 1 : 0) } + f.buttons.reduce(0) { $0 + (($1 ?? 0) > 0 ? 1 : 0) }
        + f.digits.reduce(0) { $0 + (($1 ?? 0) != 0 ? 1 : 0) } + f.strip.reduce(0) { $0 + (($1?.level ?? 0) > 0 ? 1 : 0) }
}

/// LEDs, deren Wert sich zwischen zwei Takten ändert
private func changedLEDs(_ a: LEDShow.Frame, _ b: LEDShow.Frame) -> Int {
    zip(a.pads, b.pads).filter { $0.0 != $0.1 }.count + zip(a.buttons, b.buttons).filter { $0.0 != $0.1 }.count
        + zip(a.digits, b.digits).filter { $0.0 != $0.1 }.count + zip(a.strip, b.strip).filter { $0.0 != $0.1 }.count
}

@Test func ledShowPhasesInOrderAndEndsReady() {
    #expect(LEDShow.duration >= 8.5 && LEDShow.duration <= 9.2)
    var last = LEDShow.Phase.storm
    var seen: [LEDShow.Phase] = []
    var t = 0.0
    while t < LEDShow.duration + 0.5 {
        let ph = LEDShow.phase(at: t)
        #expect(ph >= last)
        if seen.last != ph { seen.append(ph) }
        last = ph
        let f = LEDShow.frame(at: t, decks: (0, 2), seed: 7)
        #expect((f == nil) == (ph == .ready))
        if let f { #expect(f.phase == ph) }
        t += LEDShow.step
    }
    #expect(seen == [.storm, .settle, .breath, .ready])
    #expect(LEDShow.frame(at: LEDShow.duration, decks: (0, 2), seed: 7) == nil)
    // Sturm 5 s, Einpendeln 2–4 s, Atempuls 0,5 s am Ende
    #expect(LEDShow.stormEnd == 5 && LEDShow.settleEnd - LEDShow.stormEnd >= 2 && LEDShow.settleEnd - LEDShow.stormEnd <= 4)
    #expect(abs(LEDShow.duration - LEDShow.settleEnd - 0.5) < 1e-9)
}

@Test func ledShowTimeline() {
    func f(_ t: Double) -> LEDShow.Frame { LEDShow.frame(at: t, decks: (0, 2), seed: 3)! }
    // Glut und Lauflicht wie gehabt
    #expect(f(1.0).pads.allSatisfy { $0?.color == .red })
    #expect(f(2.0).pads.contains { $0 == LEDShow.Light(color: .purple, level: 1) })
    // Wirrwarr: alle LEDs noch in der Sequenz, dicht flackernd, kein Blitz
    for t in [3.6, 4.4, 4.9] {
        let w = f(t)
        #expect(w.phase == .storm && w.pads.allSatisfy { $0 != nil } && w.breath == 0)
        #expect(shownLEDs(w) > 20)
    }
    // Seite auf der Anzeige (A links, C rechts), solange die Ziffern nicht eingependelt sind
    let side = f(5.5)
    #expect(side.phase == .settle && side.digits[1] == LEDShow.mask("A") && side.digits[4] == LEDShow.mask("C"))
    // Einpendeln der Reihe nach: Pads, dann Tasten, dann Ziffern und Strip
    #expect(f(6.3).pads.allSatisfy { $0 == nil } && f(6.3).buttons.contains { $0 != nil })
    #expect(f(7.3).buttons.allSatisfy { $0 == nil } && f(7.3).strip.contains { $0 != nil })
    // Ende des Einpendelns: alles normal, Atempuls ab 8,4 s, danach bereit
    #expect(allNormal(f(LEDShow.settleEnd - 0.001)))
    for t in stride(from: LEDShow.settleEnd + LEDShow.step, to: LEDShow.duration, by: LEDShow.step) {
        let b = f(t)
        #expect(b.phase == .breath && allNormal(b) && b.breath > 0)
    }
    #expect(f(8.65).breath > 0.99)
}

@Test func ledShowFlickerCalmsDownOverLastThreeSeconds() {
    // Dichte (reine Funktion) in den letzten 3 s nie steigend, im Einpendeln auf 0
    var prev = Double.infinity
    for k in 0...300 {
        let d = LEDShow.density(at: LEDShow.duration - 3 + Double(k) * 0.01)
        #expect(d <= prev)
        prev = d
    }
    #expect(LEDShow.density(at: LEDShow.settleEnd) == 0)
    // Frames: leuchtende und wechselnde LEDs je 0,25-s-Block, gemittelt über 40 Seeds (nicht steigend bis auf Rauschen)
    var shown = [Double](repeating: 0, count: 12), changes = [Double](repeating: 0, count: 12), frames = [Double](repeating: 0, count: 12)
    for seed: UInt32 in 1...40 {
        var before: LEDShow.Frame?
        var t = LEDShow.duration - 3
        while t < LEDShow.duration {
            let block = min(11, Int((t - (LEDShow.duration - 3)) / 0.25))
            let cur = LEDShow.frame(at: t, decks: (0, 2), seed: seed)!
            shown[block] += Double(shownLEDs(cur))
            frames[block] += 1
            if let before { changes[block] += Double(changedLEDs(before, cur)) }
            before = cur
            t += LEDShow.step
        }
    }
    let lit = zip(shown, frames).map { $0 / $1 }, churn = zip(changes, frames).map { $0 / $1 }
    for k in 1..<12 {
        #expect(lit[k] <= lit[k - 1] + 0.5, "Block \(k): \(lit[k]) > \(lit[k - 1])")
        #expect(churn[k] <= churn[k - 1] + 0.5, "Block \(k): \(churn[k]) > \(churn[k - 1])")
    }
    #expect(lit[0] > lit[10] + 5)
}

@Test func ledShowSettledLEDsTakeNormalState() {
    var normal = [UInt8](repeating: 0, count: 0x34), normalDisp = [UInt8](repeating: 0, count: LEDShow.displayLength)
    normal[0x14] = 11; normal[0x15] = 22; normal[0x16] = 33      // Pad L1 normal
    normal[0x31] = 44                                           // Play links
    normalDisp[0x01] = 66; normalDisp[LEDShow.stripStart] = 77   // Ziffer 1 Segment a, Strip 1
    var f = LEDShow.Frame(phase: .settle, pads: Array(repeating: nil, count: 8),
                          buttons: Array(repeating: nil, count: LEDShow.buttons.count),
                          digits: Array(repeating: nil, count: 6), strip: Array(repeating: nil, count: LEDShow.stripCount))
    f.pads[1] = LEDShow.Light(color: .white, level: 1)           // Pad L2 zeigt das Bild
    f.buttons[0] = 1                                             // FX 1 voll
    f.digits[0] = 0xFF
    let (led, disp) = LEDShow.reports(f, peak: 100, normal: (normal, normalDisp))
    #expect(led[0x14...0x16] == normal[0x14...0x16])
    #expect(led[0x17] == 100)
    #expect(led[0x01] == 100 && led[0x02] == 0 && led[0x31] == 44)
    #expect(disp[0x01] == 100 && disp[0x08] == 100 && disp[0x09] == 0)
    #expect(disp[LEDShow.stripStart] == 77)
}

@Test func ledShowEndsOnNormalState() {
    var normal = [UInt8](repeating: 0, count: 0x34), normalDisp = [UInt8](repeating: 0, count: LEDShow.displayLength)
    normal[0] = 0x80; normalDisp[0] = 0x81
    for p in LEDShow.padBytes { normal[p] = UInt8(p); normal[p + 1] = 3; normal[p + 2] = 5 }
    for b in LEDShow.buttons { normal[b.byte] = UInt8(b.byte) }
    for i in 1..<LEDShow.displayLength { normalDisp[i] = UInt8(i % 100) }
    for seed: UInt32 in [1, 99] {
        // Ab settleEnd alles im normalen Zustand, bis zum Ende ohne Flackern
        for t in stride(from: LEDShow.settleEnd, to: LEDShow.duration, by: LEDShow.step) {
            #expect(allNormal(LEDShow.frame(at: t, decks: (0, 2), seed: seed)!))
        }
        #expect(LEDShow.frame(at: LEDShow.duration - 0.001, decks: (0, 2), seed: seed)!.breath < 0.02)
        #expect(LEDShow.frame(at: LEDShow.duration, decks: (0, 2), seed: seed) == nil)
        // Frame ohne Bild = normaler Report, Byte für Byte
        let blank = LEDShow.Frame(phase: .breath, pads: Array(repeating: nil, count: 8),
                                  buttons: Array(repeating: nil, count: LEDShow.buttons.count),
                                  digits: Array(repeating: nil, count: 6), strip: Array(repeating: nil, count: LEDShow.stripCount))
        let (led, disp) = LEDShow.reports(blank, peak: 127, normal: (normal, normalDisp))
        #expect(led == normal && disp == normalDisp)
    }
    // Atempuls dimmt nur kurz, 0 = unverändert
    #expect(LEDShow.breathPeak(127, 0) == 127 && LEDShow.breathPeak(100, 1) == 75)
}

@Test func ledShowIsPureAndShowsDeckLetters() {
    let a = LEDShow.frame(at: 6.5, decks: (0, 2), seed: 42), b = LEDShow.frame(at: 6.5, decks: (0, 2), seed: 42)
    #expect(a == b)
    let left = LEDShow.frame(at: 5.5, decks: (0, 2), seed: 1)!
    #expect(left.digits[1] == LEDShow.mask("A") && left.digits[4] == LEDShow.mask("C"))
    let right = LEDShow.frame(at: 5.5, decks: (1, 3), seed: 1)!
    #expect(right.digits[1] == LEDShow.mask("b") && right.digits[4] == LEDShow.mask("d"))
    // Seitenwechsel startet mit den Decks auf der Anzeige
    let side = LEDShow.frame(at: LEDShow.sideAt, decks: (1, 3), seed: 1)!
    #expect(side.digits[1] == LEDShow.mask("b") && side.digits[4] == LEDShow.mask("d"))
}

@Test func ledShowPadColorsOnlyFromPalette() {
    let palette = LEDShow.Color.allCases.map(LEDShow.rgb)
    let zeroLed = [UInt8](repeating: 0, count: 0x34), zeroDisp = [UInt8](repeating: 0, count: LEDShow.displayLength)
    var lit = 0, colors = Set<Int>()
    for seed: UInt32 in [1, 99, 12345] {
        var t = 0.0
        while let f = LEDShow.frame(at: t, decks: (1, 3), seed: seed) {
            let (led, _) = LEDShow.reports(f, peak: 110, normal: (zeroLed, zeroDisp))
            for base in LEDShow.padBytes {
                let c = (Int(led[base]), Int(led[base + 1]), Int(led[base + 2]))
                if c == (0, 0, 0) { continue }
                lit += 1
                // jede leuchtende Pad-Farbe = Palettenfarbe × Helligkeit
                let match = palette.firstIndex { p in
                    let k = Double(c.0) / Double(p.r)
                    return abs(Double(p.g) * k - Double(c.1)) <= 1.5 && abs(Double(p.b) * k - Double(c.2)) <= 1.5
                }
                #expect(match != nil, "Pad-Farbe \(c) nicht aus der Palette")
                if let match { colors.insert(match) }
            }
            for case let l? in f.strip + f.pads { #expect(l.level >= 0 && l.level <= 1) }
            for case let l? in f.buttons { #expect(l >= 0 && l <= 1) }
            t += LEDShow.step
        }
    }
    #expect(lit > 100 && colors.count == 3)   // rot, weiß und lila kommen alle vor
}

@Test func ledShowSegmentLetters() {
    // A b C d auf der 7-Segment-Anzeige (1 = g, 2 = c, 3 = b, 4 = a, 5 = f, 6 = e, 7 = d)
    #expect(LEDShow.mask("A") == 0b0111_1110 && LEDShow.mask("C") == 0b1111_0000)
    #expect(LEDShow.letter(0) == "A" && LEDShow.letter(1) == "b" && LEDShow.letter(2) == "C" && LEDShow.letter(3) == "d")
}
