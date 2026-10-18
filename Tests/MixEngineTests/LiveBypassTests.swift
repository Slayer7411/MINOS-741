import Foundation
import Testing
@testable import MixEngine

// LIVE-Absturzschutz: welche Plugin-Slots bei LIVE trocken laufen (Regel) und welche der Controller meldet.

@Test func liveBypassRule() {
    // nur bei LIVE, eingeschalteter Einstellung und einer VST3-Instanz im Prozess
    #expect(LiveBypass.bypassed(live: true, enabled: true, vst3InProcess: true))
    #expect(!LiveBypass.bypassed(live: false, enabled: true, vst3InProcess: true))
    #expect(!LiveBypass.bypassed(live: true, enabled: false, vst3InProcess: true))
    // Audio Units (eigener Dienst) und eingebaute Effekte bleiben aktiv
    #expect(!LiveBypass.bypassed(live: true, enabled: true, vst3InProcess: false))
    // Schalter: überbrückt = aus, sonst wie eingestellt
    #expect(!LiveBypass.effectiveOn(true, bypassed: true))
    #expect(!LiveBypass.effectiveOn(false, bypassed: true))
    #expect(LiveBypass.effectiveOn(true, bypassed: false))
    #expect(!LiveBypass.effectiveOn(false, bypassed: false))
}

private func waitForLiveBypass(_ seconds: Double = 20, _ cond: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !cond(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

/// Controller: bei LIVE + Einstellung werden nur eingeschaltete VST3-Slots gemeldet (AU nicht), Umschalten wirkt sofort
@Test func liveBypassNamesFollowVST3Slots() async throws {
    let src = try #require(VST3Fixture.bundle)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos-live-bypass-\(UUID().uuidString.prefix(8))")
    let folder = dir.appendingPathComponent("vst3")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.copyItem(at: src, to: folder.appendingPathComponent(src.lastPathComponent))
    let core = MixController()
    let cat = PluginCatalog(directory: dir.appendingPathComponent("store"), folders: [], vst3Folders: [])
    cat.update { $0.folders = [folder.path]; $0.allowInProcess = true }
    core.pluginCatalog = cat
    core.setSlots(0, [])
    core.addSlot(0, id: "aufx:lpas:appl")
    core.addSlot(0, id: "vst3:C18D3C1E719E4E29924D3ECAA5E4DA18")
    try await waitForLiveBypass { core.pluginInstance(0, slot: 1) != nil && core.pluginInstance(0, slot: 0) != nil }
    let vst3Name = try #require(core.pluginInstance(0, slot: 1)?.info.name)

    // LIVE aus: nichts überbrückt
    #expect(core.liveBypassNames().isEmpty)
    // LIVE an, Einstellung an: nur das VST3-Plugin (die Audio Unit läuft weiter)
    core.setLiveBypass(live: true, vst3: true)
    #expect(core.liveBypassNames() == [vst3Name])
    // Einstellung aus: wieder nichts
    core.setLiveBypass(live: true, vst3: false)
    #expect(core.liveBypassNames().isEmpty)
    core.setLiveBypass(live: true, vst3: true)
    // ausgeschalteter Slot zählt nicht (er rechnet ohnehin nicht)
    core.setSlotOn(0, slot: 1, false)
    #expect(core.liveBypassNames().isEmpty)
    core.setSlotOn(0, slot: 1, true)
    #expect(core.liveBypassNames() == [vst3Name])
    // LIVE aus: wieder frei
    core.setLiveBypass(live: false, vst3: true)
    #expect(core.liveBypassNames().isEmpty)
}
