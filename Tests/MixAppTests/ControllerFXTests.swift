import Foundation
import Testing
import MixCore
@testable import MixEngine
@testable import MixApp

// FX-Regler und -Tasten des Controllers = Schnellregler und Tasten der Unit (FX-Belegung, kein Sonderfall im Controller).

@MainActor @Test func controllerFXKnobsAndButtonsFollowMapping() {
    let core = testController()
    let manager = ControllerManager(core: core, status: ControllerStatus())
    let u = ControllerUnit(device: nil, info: .init(id: "FX", location: 0, left: 0, right: 1), manager: manager)
    func fx(_ i: Int) -> FXUnitState { core.snapshot().fx[i] }

    // Standard (Vorlage Gruppe): linke Sektion = FX 1, Regler 1 = Filter, Taste 1 = Filter an/aus, D/W = Unit
    manager.handle(.fxKnob(0, 1, 0.8), unit: u)
    manager.handle(.fxKnob(0, 0, 0.6), unit: u)
    manager.handle(.fxButton(0, 1, true), unit: u)
    manager.handle(.fxButton(0, 1, false), unit: u)
    #expect(fx(0).slots[0].params["cutoff"] == 0.8 && fx(0).dryWet == 0.6 && fx(0).slots[0].on)

    // umbelegt: Regler 1 = Raumgröße, Taste 2 = Delay-Zeit, Taste 3 aus, D/W = Anteil des Delay-Slots
    core.setFXMapping(0, .knob1, "s2.size")
    core.setFXMapping(0, .button2, "s1.rate")
    core.setFXMapping(0, .button3, "")
    core.setFXMapping(0, .dryWet, "s1.mix")
    let rate = fx(0).slots[1].params["rate"] ?? 0.6, reverbOn = fx(0).slots[2].on
    manager.handle(.fxKnob(0, 1, 0.25), unit: u)
    manager.handle(.fxKnob(0, 0, 0.9), unit: u)
    manager.handle(.fxButton(0, 2, true), unit: u)
    manager.handle(.fxButton(0, 3, true), unit: u)
    #expect(fx(0).slots[2].params["size"] == 0.25 && fx(0).slots[0].params["cutoff"] == 0.8)
    #expect(fx(0).slots[1].mix == 0.9 && fx(0).dryWet == 0.6)
    #expect(abs((fx(0).slots[1].params["rate"] ?? 0) - (rate + 0.2)) < 1e-9 && fx(0).slots[2].on == reverbOn)

    // rechte Sektion = FX 2 mit eigener (Standard-)Belegung; ein Slot: Taste 1 = an/aus, Mode = alle aus / wieder an
    core.setSlots(1, [FXSlot(id: "REVERB")])
    manager.handle(.fxKnob(1, 3, 0.7), unit: u)
    manager.handle(.fxButton(1, 1, true), unit: u)
    #expect(fx(1).slots[0].params["lp"] == 0.7 && fx(1).slots[0].on)
    manager.handle(.fxButton(1, 0, true), unit: u)
    #expect(!fx(1).slots[0].on)
    manager.handle(.fxButton(1, 0, true), unit: u)
    #expect(fx(1).slots[0].on)
    manager.handle(.fxButton(1, 3, true), unit: u)   // Taste 3: bei einem Slot REVERB frei
    #expect(fx(1).slots[0].on && fx(1).slots.count == 1)
}

/// Beat-FX über den Controller: Gater/Flanger in der Gruppe, Phaser als einziger Slot, Shift + Mode = nächste Vorlage
@MainActor @Test func controllerBeatFX() {
    let core = testController()
    let manager = ControllerManager(core: core, status: ControllerStatus())
    let u = ControllerUnit(device: nil, info: .init(id: "FX", location: 0, left: 0, right: 1), manager: manager)
    func fx(_ i: Int) -> FXUnitState { core.snapshot().fx[i] }
    core.replaceSlot(0, slot: 0, id: "GATER")
    core.replaceSlot(0, slot: 1, id: "FLANGER")
    manager.handle(.fxKnob(0, 1, 0.9), unit: u)
    manager.handle(.fxKnob(0, 2, 0.3), unit: u)
    manager.handle(.fxButton(0, 1, true), unit: u)
    manager.handle(.fxButton(0, 2, true), unit: u)
    #expect(fx(0).slots[0].mix == 0.9 && fx(0).slots[0].on && fx(0).slots[1].mix == 0.3 && fx(0).slots[1].on)
    core.setSlots(1, [FXSlot(id: "PHASER")])
    manager.handle(.fxButton(1, 1, true), unit: u)
    manager.handle(.fxButton(1, 2, true), unit: u)
    manager.handle(.fxButton(1, 3, true), unit: u)
    #expect(fx(1).slots[0].on && fx(1).slots[0].params["freeze"] == 1 && fx(1).slots[0].params["stages"] == 1)
    u.shift = true
    manager.handle(.fxButton(1, 0, true), unit: u)
    u.shift = false
    // nach PHASER (letzte Vorlage) wieder die Gruppe; an bleibt an
    #expect(fx(1).slots.map(\.id) == ["FILTER", "DELAY", "REVERB"] && fx(1).slots.allSatisfy(\.on))
}
