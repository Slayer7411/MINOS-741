import Foundation
import Testing
@testable import MixEngine

// FX-Belegung: D/W, Regler 1–3, Tasten 1–3 je Unit auf Parameter aller Slots (eingebaut, AU, VST3),
// gemerkt je Rack-Kennung (EnginePrefs.fxMappings), Unit-Belegung in der Sitzung (FXUnitState).

private func control(_ s: MixState, _ u: Int, _ c: FXControl) -> FXControlInfo { s.fxControls[u][c.slot] }

private func waitFor(_ seconds: Double = 15, _ cond: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !cond(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("minos-fxassign-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Katalog nur mit eigenem Ordner (keine System-VST3-Ordner einlesen)
private func catalog(_ dir: URL, vst3: URL? = nil) -> PluginCatalog {
    let c = PluginCatalog(directory: dir.appendingPathComponent("store"), folders: [], vst3Folders: [])
    if let vst3 { c.update { $0.folders = [vst3.path]; $0.allowInProcess = true } }   // VST3 läuft nur im Prozess
    return c
}

private let group = "FILTER > DELAY > REVERB"

/// Vorlage Gruppe = früherer Gruppenmodus; ein Slot = früherer Single-Modus
@Test func fxDefaultMappingKeepsOldLayout() {
    let core = testController()
    var s = core.snapshot()
    #expect(s.fx[0].effectKey == group)
    #expect(s.fxControls[0].map(\.label) == ["D/W", "FILTER", "DELAY", "REVERB", "ON", "ON", "ON"])
    #expect(s.fxControls[0].allSatisfy { $0.isDefault })
    // Gruppe: Regler = Stärke (Filter: Cutoff, sonst Anteil), Tasten = Slot an/aus
    core.setFXControl(0, .knob1, 0.8)
    core.setFXControl(0, .knob2, 0.3)
    core.setFXControl(0, .dryWet, 0.4)
    core.pressFXButton(0, 1)
    s = core.snapshot()
    #expect(s.fx[0].slots[0].params["cutoff"] == 0.8 && s.fx[0].slots[1].mix == 0.3 && s.fx[0].dryWet == 0.4)
    #expect(s.fx[0].slots[1].on && !s.fx[0].slots[0].on)
    #expect(control(s, 0, .button2).active && !control(s, 0, .button1).active)
    // ein Slot Delay: Regler 3 = Delay-Zeit (6 Stufen), Taste 1 = an/aus, Tasten 2/3 frei
    core.setSlots(1, [FXSlot(id: "DELAY")])
    s = core.snapshot()
    #expect(s.fxControls[1].map(\.label) == ["D/W", "FILTER", "FEEDB", "RATE", "ON", "—", "—"])
    core.setFXControl(1, .knob3, 0.33)
    core.pressFXButton(1, 0)
    core.pressFXButton(1, 2)
    s = core.snapshot()
    #expect(abs((s.fx[1].slots[0].params["rate"] ?? 0) - 0.4) < 1e-9)   // gerastet auf Stufe 2 (3/4 Beat)
    #expect(control(s, 1, .knob3).param?.text(s.fx[1].slots[0].params["rate"] ?? 0) == "3/4")
    #expect(s.fx[1].slots[0].on && !control(s, 1, .button3).active)
    // zweiter eingebauter Slot dahinter: Gruppen-Belegung (Regler je Slot), Taste 2 = an/aus von Slot 2
    core.addSlot(1, id: "REVERB")
    s = core.snapshot()
    #expect(s.fxControls[1].map(\.label) == ["D/W", "DELAY", "REVERB", "—", "ON", "ON", "—"])
    #expect(control(s, 1, .button2).param?.id == "s1.on")
}

@Test func fxMappingRemapsAndIsRememberedPerRack() {
    let core = testController()
    core.setFXMapping(0, .knob1, "s2.size")
    core.setFXMapping(0, .knob2, "")
    core.setFXMapping(0, .button2, "s1.rate")
    var s = core.snapshot()
    #expect(s.prefs.fxMappings[group]?[.knob1] == "s2.size")
    #expect(control(s, 0, .knob1).label == "SIZE" && !control(s, 0, .knob1).isDefault)
    #expect(control(s, 0, .knob2).param == nil && control(s, 0, .knob2).label == "—")
    let cutoff = FXCatalog.param(s.fx[0].slots[0], "cutoff"), delay = s.fx[0].slots[1].mix
    core.setFXControl(0, .knob1, 0.3)
    core.setFXControl(0, .knob2, 0.9)   // nicht zugewiesen: nichts
    s = core.snapshot()
    #expect(s.fx[0].slots[2].params["size"] == 0.3 && FXCatalog.param(s.fx[0].slots[0], "cutoff") == cutoff && s.fx[0].slots[1].mix == delay)
    // Liste: eine Stufe weiter, am Ende zurück auf die erste
    let step = { Int(((core.snapshot().fx[0].slots[1].params["rate"] ?? 0.6) * 5).rounded()) }
    let start = step()
    for n in 1...MixEngine.delayBeats.count {
        core.pressFXButton(0, 1)
        #expect(step() == (start + n) % MixEngine.delayBeats.count)
    }
    // anderes Rack: dessen Belegung (hier Standard); zurück zur Vorlage Gruppe: gemerkte Belegung wieder da
    core.setSlots(0, [FXSlot(id: "FILTER")])
    s = core.snapshot()
    #expect(s.fx[0].mapping.isEmpty && s.fx[0].mappingKey == "FILTER" && control(s, 0, .knob1).label == "CUTOFF")
    core.applyTemplate(0, .group)
    s = core.snapshot()
    #expect(s.fx[0].mapping[.knob1] == "s2.size" && control(s, 0, .knob1).label == "SIZE")
    // andere Unit behält ihre eigene Belegung
    #expect(control(s, 1, .knob1).label == "FILTER")
    // Standard wiederherstellen: aus den Einstellungen entfernt
    core.resetFXMapping(0)
    s = core.snapshot()
    #expect(s.fx[0].mapping.isEmpty && s.prefs.fxMappings[group] == nil && control(s, 0, .knob1).label == "FILTER")
}

/// gemerkte Belegung der früheren Gruppe (Einstellungen) und eigene der Sitzung kommen übersetzt an
@Test func fxMappingFromPrefsAndSessionWins() throws {
    var prefs = EnginePrefs()
    var m = FXMapping()
    m[.knob3] = "reverb.size"
    m[.button1] = ""
    prefs.fxMappings["GROUP"] = m
    prefs = try JSONDecoder().decode(EnginePrefs.self, from: JSONEncoder().encode(prefs))
    let core = testController()
    core.setPrefs(prefs)
    var s = core.snapshot()
    #expect(s.prefs.fxMappings["GROUP"] == nil && s.prefs.fxMappings[group]?[.knob3] == "s2.size")
    #expect(control(s, 0, .knob3).label == "SIZE" && control(s, 0, .button1).param == nil)
    #expect(control(s, 2, .knob3).label == "SIZE")
    // Sitzung (alte Fassung): eigene Belegung der Unit geht vor die gemerkte
    let old = #"{"dryWet":1,"mapping":{"k1":"delay"},"mappingKey":"GROUP"}"#
    let saved = try JSONDecoder().decode(FXUnitState.self, from: Data(old.utf8))
    #expect(saved.mapping[.knob1] == "s1.mix" && saved.mappingKey == group)
    core.restore { $0.fx[0] = saved }
    s = core.snapshot()
    #expect(control(s, 0, .knob1).label == "DELAY" && control(s, 0, .knob3).label == "REVERB")
    #expect(s.prefs.fxMappings[group]?[.knob3] == "s2.size")
}

@Test func fxParamScalesAndFormats() {
    var f = FXParam(id: "p1", name: "Filter Frequency", short: "FILTER", unit: "Hz", min: 10, max: 22050)
    f.curve = .logarithmic
    #expect(abs(f.plain(0.5) - (10 * 22050).squareRoot()) < 0.01)
    for x in [0.0, 0.2, 0.77, 1.0] { #expect(abs(f.position(f.plain(x)) - x) < 1e-9) }
    #expect(f.text(1) == "22.05 kHz" && f.text(0) == "10 Hz")
    let list = FXParam(id: "p2", name: "Mode", short: "MODE", min: 0, max: 2, steps: 2, valueNames: ["A", "B", "C"])
    #expect(list.snapped(0.6) == 0.5 && list.text(0.6) == "B" && list.plain(1) == 2)
    let db = FXParam(id: "p3", name: "Gain", short: "GAIN", unit: "dB", min: -18, max: 18)
    #expect(db.text(0.5) == "+0.0 dB")
    #expect(FXParam.shortName("Small/Large Mix") == "SMALL/L" && FXParam.shortName("Gain") == "GAIN")
}

/// Audio Unit (Apple, im Prozess): Parameterbaum mit Einheit, Bereich, Gruppe, Kurve; D/W auf den Mix des Plugins
@Test func fxMappingDrivesAudioUnitParameterTree() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let core = testController()
    core.pluginCatalog = catalog(dir)
    let id = "aufx:mrev:appl"
    core.setSlots(0, [FXSlot(id: id)])
    try await waitFor { core.snapshot().fxParams[0].contains { $0.pluginParam != nil } }
    var s = core.snapshot()
    let params = s.fxParams[0].filter { $0.pluginParam != nil }
    #expect(params.count >= 10)
    let mix = try #require(params.first { $0.name == "Dry/Wet Mix" })
    let freq = try #require(params.first { $0.name == "Filter Frequency" })
    #expect(mix.unit == "%" && mix.max == 100 && !mix.group.isEmpty)
    #expect(freq.unit == "Hz" && freq.curve == .logarithmic)
    #expect(Set(params.map(\.group)).count >= 3)
    // Standard: Regler 1–3 = erste drei Parameter, D/W = Unit, Taste 1 = Slot an/aus
    #expect(control(s, 0, .knob1).param?.id == params[0].id && control(s, 0, .dryWet).param?.id == "dw")
    #expect(control(s, 0, .button1).param?.id == "on")
    // D/W -> Mix des Plugins, Regler 2 -> Filterfrequenz
    core.setFXMapping(0, .dryWet, mix.id)
    core.setFXMapping(0, .knob2, freq.id)
    core.setFXControl(0, .dryWet, 0.3)
    core.setFXControl(0, .knob2, 0.5)
    let inst = try #require(core.beginPluginEdit(0))
    defer { core.endPluginEdit(0, inst) }
    #expect(abs(inst.value(mix.pluginParam!) - 30) < 0.01)
    // logarithmisch: Regler 0,5 = geometrisches Mittel des Parameterbereichs (die Obergrenze hängt von der Rate des Plugins ab)
    #expect(abs(Double(inst.value(freq.pluginParam!)) - (freq.min * freq.max).squareRoot()) < 1)
    s = core.snapshot()
    #expect(!s.fxControls[0].contains { $0.param?.id == "dw" })   // Unit-D/W aus dem Spiel -> voll nass
    #expect(abs(control(s, 0, .dryWet).value - 0.3) < 1e-6 && control(s, 0, .dryWet).label == "DRY/WET")
    #expect(s.prefs.fxMappings[id]?[.dryWet] == mix.id)
    #expect(core.pluginParamNames(0).count == 3)
    core.setSlots(0, [])
}

/// VST3 (Test-Plugin "AGain Sample Accurate"): Regler/Taste auf Gain, gemerkt je Plugin-ID, Sitzung setzt die Stellung wieder
@Test func fxMappingDrivesVST3AndComesBackWithSession() async throws {
    let src = try #require(VST3Fixture.bundle)
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("vst3")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: src, to: folder.appendingPathComponent(src.lastPathComponent))
    let id = "vst3:C18D3C1E719E4E29924D3ECAA5E4DA18"

    let core = testController()
    core.pluginCatalog = catalog(dir, vst3: folder)
    core.setSlots(0, [FXSlot(id: id)])
    try await waitFor { core.snapshot().fxParams[0].contains { $0.pluginParam != nil } }
    var s = core.snapshot()
    let gain = try #require(s.fxParams[0].first { $0.name == "Gain" })
    let pid = try #require(gain.pluginParam)
    #expect(gain.unit == "%" && gain.normalized && gain.steps == 0)
    #expect(control(s, 0, .knob1).param?.id == gain.id && control(s, 0, .knob2).param == nil)
    #expect(control(s, 0, .button1).param?.id == "on")

    core.setFXMapping(0, .knob3, gain.id)
    core.setFXMapping(0, .knob1, "")
    core.setFXMapping(0, .button2, gain.id)
    let inst = try #require(core.beginPluginEdit(0))
    core.setFXControl(0, .knob3, 0.25)
    #expect(abs(inst.value(pid) - 0.25) < 1e-6)
    core.setFXControl(0, .knob1, 0.9)   // nicht zugewiesen
    #expect(abs(inst.value(pid) - 0.25) < 1e-6)
    // Taste auf stufenlosem Parameter: min/max
    core.pressFXButton(0, 1)
    #expect(inst.value(pid) == 1 && control(core.snapshot(), 0, .button2).active)
    core.pressFXButton(0, 1)
    #expect(inst.value(pid) == 0)
    core.setFXControl(0, .knob3, 0.6)
    s = core.snapshot()
    #expect(abs(control(s, 0, .knob3).value - 0.6) < 1e-9 && control(s, 0, .knob3).label == "GAIN")
    #expect(core.pluginText(0, gain, 0.6)?.hasSuffix("%") == true)
    core.endPluginEdit(0, inst)
    #expect(s.prefs.fxMappings[id]?[.knob3] == gain.id && s.prefs.fxMappings[id]?[.knob1] == "")

    // Neustart: Einstellungen + gespeicherte Unit (Plugin-Zustand von vor den Reglern) -> Stellung 0,6 kommt zurück
    let session = try JSONEncoder().encode(core.snapshot().fx[0])
    let prefs = core.snapshot().prefs
    // anderer Effekt im Slot: Belegung des neuen Racks (Standard)
    core.replaceSlot(0, slot: 0, id: "REVERB")
    #expect(core.snapshot().fx[0].mappingKey == "REVERB" && core.snapshot().fx[0].mapping.isEmpty)
    core.setSlots(0, [])
    let next = testController()
    next.pluginCatalog = catalog(dir, vst3: folder)
    next.setPrefs(prefs)
    let fx = try JSONDecoder().decode(FXUnitState.self, from: session)
    #expect(fx.slots[0].state != nil && fx.pluginValues[gain.id] == 0.6)
    next.restore { $0.fx[0] = fx }
    try await waitFor { next.snapshot().fxParams[0].contains { $0.pluginParam != nil } }
    let inst2 = try #require(next.beginPluginEdit(0))
    defer { next.endPluginEdit(0, inst2) }
    #expect(abs(inst2.value(pid) - 0.6) < 1e-6)
    s = next.snapshot()
    #expect(control(s, 0, .knob3).param?.id == gain.id && abs(control(s, 0, .knob3).value - 0.6) < 1e-9)
    #expect(control(s, 0, .knob1).param == nil)
    next.setSlots(0, [])
}

/// ein Slot REVERB: Taste 2 = Freeze (FRZ), Gruppe: Freeze zuweisbar; Freeze kommt nicht aus der Sitzung zurück
@Test func fxReverbFreezeButton() throws {
    let core = testController()
    core.setSlots(1, [FXSlot(id: "REVERB")])
    var s = core.snapshot()
    #expect(s.fxControls[1].map(\.label) == ["D/W", "SIZE", "HP", "LP", "ON", "FRZ", "—"])
    core.pressFXButton(1, 1)
    s = core.snapshot()
    #expect(s.fx[1].slots[0].params["freeze"] == 1 && control(s, 1, .button2).active)
    let again = try JSONDecoder().decode(FXUnitState.self, from: JSONEncoder().encode(s.fx[1]))
    #expect(again.slots[0].params["freeze"] == nil && again.slots[0].id == "REVERB")
    core.setFXMapping(0, .button3, "s2.freeze")
    core.pressFXButton(0, 2)
    #expect(core.snapshot().fx[0].slots[2].params["freeze"] == 1 && control(core.snapshot(), 0, .button3).label == "FRZ")
    #expect(core.snapshot().prefs.reverbType == .classic)
}

/// Beat-FX als einziger Slot: Standardbelegung, Stufen, Flanger frei = Regler 1 auf Hz; Freeze/Mute nicht aus der Sitzung
@Test func fxBeatEffectsSingleMapping() throws {
    let core = testController()
    func single(_ e: FXUnitState.Effect) -> MixState { core.replaceSlot(1, slot: 0, id: e.name); return core.snapshot() }
    core.setSlots(1, [FXSlot(id: "DELAY")])
    var s = single(.gater)
    #expect(s.fxControls[1].map(\.label) == ["D/W", "RATE", "SHAPE", "WIDTH", "ON", "MUTE", "TRIP"])
    #expect(control(s, 1, .knob1).param?.text(control(s, 1, .knob1).value) == "1/4")
    core.setFXControl(1, .knob1, 0.4)
    core.pressFXButton(1, 1)
    s = core.snapshot()
    #expect(control(s, 1, .knob1).param?.text(s.fx[1].slots[0].params["rate"] ?? 0) == "1/8" && s.fx[1].slots[0].params["mute"] == 1)
    s = single(.roll)
    #expect(s.fxControls[1].map(\.label) == ["D/W", "LEN", "FILTER", "DECAY", "ON", "REV", "—"])
    #expect(control(s, 1, .knob1).param?.valueNames == ["1/32", "1/16", "1/8", "1/4", "1/2", "1"])
    s = single(.flanger)
    #expect(s.fxControls[1].map(\.label) == ["D/W", "RATE", "DEPTH", "FEEDB", "ON", "FRZ", "SYNC"])
    #expect(control(s, 1, .knob1).param?.text(control(s, 1, .knob1).value) == "4" && control(s, 1, .button3).active)
    core.pressFXButton(1, 2)   // SYNC aus: Regler 1 = Rate in Hz
    core.pressFXButton(1, 1)   // LFO-Freeze
    s = core.snapshot()
    #expect(control(s, 1, .knob1).label == "HZ" && control(s, 1, .knob1).param?.text(0.5) == "0.28 Hz")
    let flanger = try JSONDecoder().decode(FXUnitState.self, from: JSONEncoder().encode(s.fx[1]))
    #expect(flanger.slots[0].params["sync"] == 0 && flanger.slots[0].params["freeze"] == nil)
    s = single(.phaser)
    #expect(s.fxControls[1].map(\.label) == ["D/W", "RATE", "DEPTH", "FEEDB", "ON", "FRZ", "STAGE"])
    core.pressFXButton(1, 2)
    #expect(control(core.snapshot(), 1, .button3).param?.text(1) == "8" && core.snapshot().fx[1].slots[0].params["stages"] == 1)
    // Weiterschalten (Controller: Shift + Mode): Vorlagen, Gruppe zuerst, dann die eingebauten
    #expect(FXTemplate.all.map(\.name) == ["GRUPPE FLT·DLY·REV", "FILTER", "DELAY", "REVERB", "GATER", "ROLL", "FLANGER", "PHASER"])
    #expect(FXTemplate.index(of: core.snapshot().fx[1].slots) == 7)
    core.fxModeButton(1, shift: true)
    #expect(core.snapshot().fx[1].slots.map(\.id) == ["FILTER", "DELAY", "REVERB"])
    core.fxModeButton(1, shift: true)
    #expect(core.snapshot().fx[1].slots.map(\.id) == ["FILTER"])
}

/// Mode-Taste: alle Slots aus (gemerkt, welche an waren), wieder an
@Test func fxModeButtonRemembersSlots() {
    let core = testController()
    core.updateFX(0) { $0.slots[0].on = true; $0.slots[2].on = true }
    core.fxModeButton(0, shift: false)
    #expect(core.snapshot().fx[0].slots.map(\.on) == [false, false, false])
    core.fxModeButton(0, shift: false)
    #expect(core.snapshot().fx[0].slots.map(\.on) == [true, false, true])
    core.fxModeButton(0, shift: false)
    core.updateFX(1) { _ in }
    core.fxModeButton(1, shift: false)   // nichts gemerkt: alle an
    #expect(core.snapshot().fx[1].slots.map(\.on) == [true, true, true])
}

/// Slots: eingebaute je einmal (Wahl eines schon belegten tauscht die Plätze), höchstens slotCount, Gruppen-Belegung je Slot
@Test func fxSlotsRulesAndGroupLayout() throws {
    let core = testController()
    core.replaceSlot(0, slot: 0, id: "GATER")
    core.replaceSlot(0, slot: 2, id: "ROLL")
    var s = core.snapshot()
    #expect(s.fx[0].effectKey == "GATER > DELAY > ROLL")
    #expect(s.fxControls[0].map(\.label) == ["D/W", "GATER", "DELAY", "ROLL", "ON", "ON", "ON"])
    #expect(s.fxParams[0].map(\.id).contains("rate") && !s.fxParams[0].contains { $0.id == "cutoff" })
    core.setFXControl(0, .knob1, 0.7)
    core.setFXControl(0, .knob3, 0.0)
    core.pressFXButton(0, 0)
    s = core.snapshot()
    #expect(s.fx[0].slots[0].mix == 0.7 && s.fx[0].slots[0].on && s.fx[0].slots[2].params["len"] == 0)
    #expect(control(s, 0, .knob3).param?.text(control(s, 0, .knob3).value) == "1/32")
    core.setFXMapping(0, .button2, "rate")
    core.pressFXButton(0, 1)
    s = core.snapshot()
    #expect(s.prefs.fxMappings["GATER > DELAY > ROLL"]?[.button2] == "rate" && s.fx[0].slots[0].params["rate"] == 1)
    // schon belegter Effekt: Slots tauschen (mit Anteil und an/aus)
    core.replaceSlot(0, slot: 1, id: "GATER")
    s = core.snapshot()
    #expect(s.fx[0].slots.map(\.id) == ["DELAY", "GATER", "ROLL"] && s.fx[0].slots[1].mix == 0.7 && s.fx[0].slots[1].on)
    // zweites Delay wird nicht angenommen, Plugins mehrfach schon
    #expect(!core.addSlot(0, id: "DELAY"))
    #expect(core.addSlot(0, id: "aufx:lpas:appl") && core.addSlot(0, id: "aufx:lpas:appl"))
    #expect(core.addSlot(0, id: "FILTER") == (MixEngine.slotCount > 5))
    while core.addSlot(0, id: "aufx:hpas:appl") {}
    #expect(core.snapshot().fx[0].slots.count == MixEngine.slotCount)
    #expect(FXRules.valid([FXSlot(id: "DELAY"), FXSlot(id: "DELAY"), FXSlot(id: "x:y:z")]).map(\.id) == ["DELAY", "x:y:z"])
    core.setSlots(0, [])
    #expect(core.snapshot().fxControls[0].map(\.label) == ["D/W", "—", "—", "—", "—", "—", "—"])
}
