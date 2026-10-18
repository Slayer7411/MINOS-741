import Foundation
import Testing
import MixDSP
@testable import MixEngine

/// VST3-Host mit einem echten Plugin: das SDK-Beispiel "again_sampleaccurate" (Gain, Bypass; eigene Controller-Klasse),
/// einmal je Testlauf aus Tests/Fixtures/VST3Plugin in einen temporären Ordner gebaut – nie nach ~/Library/Audio.

enum VST3Fixture {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// gebautes Bundle (nil, wenn der Bau scheitert – dann schlagen die Tests mit #require fehl)
    static let bundle: URL? = {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("minos-vst3-fixture-\(getpid())")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [root.appendingPathComponent("scripts/build-vst3-fixture.sh").path, out.path]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let t0 = Date()
        guard (try? p.run()) != nil else { return nil }
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        print(String(format: "[vst3] Test-Plugin gebaut in %.1f s", Date().timeIntervalSince(t0)))
        guard p.terminationStatus == 0 else { print(log); return nil }
        return out.appendingPathComponent("again-sampleaccurate.vst3")
    }()

    static let gainName = "AGain Sample Accurate"
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("minos-vst3-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func gainInfo() throws -> PluginInfo {
    let b = try #require(VST3Fixture.bundle)
    let r = PluginHost.vst3Classes(b)
    return try #require(r.classes.first { $0.name == VST3Fixture.gainName }, "\(r.error ?? "")")
}

/// Rauschen (Pegel ~0.17 rms) durch den Kern: FX 1 auf Deck A, D/W 1, Plugin an. Liefert den mittleren RMS nach 0,3 s
/// und ob alles endlich blieb
private func throughCore(_ inst: PluginInstance, fs: Double = 48000, seconds: Double = 1, change: ((Int) -> Void)? = nil)
    -> (rms: Float, finite: Bool) {
    let e = mdsp_create(fs)!
    defer { mdsp_destroy(e) }
    let frames = Int(fs * (seconds + 1))
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { l.deallocate(); r.deallocate() }
    var seed: UInt32 = 1234
    for i in 0..<frames { seed = seed &* 1664525 &+ 1013904223; let v = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6; l[i] = v; r[i] = v }
    mdsp_set_track(e, 0, l, r, Int64(frames), fs, 0)
    mdsp_set_param(e, 0, MD_FX1_ASSIGN, 1)
    setSlotPlugin(e, 0, 0, inst.ptr)
    mdsp_set_fx(e, 0, MDFX_DRYWET, 1); mdsp_set_fx_slot(e, 0, 0, true, 1)
    mdsp_set_param(e, 0, MD_PLAYING, 1)
    var outL = [Float](repeating: 0, count: 512), outR = [Float](repeating: 0, count: 512)
    var acc: Float = 0, n = 0, finite = true
    let blocks = Int(seconds * fs / 512)
    for b in 0..<blocks {
        change?(b)
        outL.withUnsafeMutableBufferPointer { lp in
            outR.withUnsafeMutableBufferPointer { rp in
                var ch: [UnsafeMutablePointer<Float>?] = [lp.baseAddress, rp.baseAddress]
                ch.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, 512) }
            }
        }
        finite = finite && outL.allSatisfy(\.isFinite) && outR.allSatisfy(\.isFinite)
        if b > Int(0.3 * fs / 512) { acc += (outL.reduce(0) { $0 + $1 * $1 } / 512).squareRoot(); n += 1 }
    }
    // Übergabe: das Plugin ist erst nach einem Block ohne es frei
    setSlotPlugin(e, 0, 0, nil)
    #expect(!mdsp_fx_plugin_released(e, 0, 0, inst.ptr))
    outL.withUnsafeMutableBufferPointer { lp in
        outR.withUnsafeMutableBufferPointer { rp in
            var ch: [UnsafeMutablePointer<Float>?] = [lp.baseAddress, rp.baseAddress]
            ch.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, 512) }
        }
    }
    #expect(mdsp_fx_plugin_released(e, 0, 0, inst.ptr))
    return (acc / Float(max(n, 1)), finite)
}

@Test func vst3BundleExposesEffectClasses() throws {
    let b = try #require(VST3Fixture.bundle)
    let r = PluginHost.vst3Classes(b)
    #expect(r.error == nil)
    // zwei Effekte, die Test-Fabrik (kTestClass) und die Controller-Klassen nicht
    #expect(Set(r.classes.map(\.name)) == [VST3Fixture.gainName, "Advanced Tutorial"])
    let g = try #require(r.classes.first { $0.name == VST3Fixture.gainName })
    #expect(g.id == "vst3:C18D3C1E719E4E29924D3ECAA5E4DA18")
    #expect(g.isVST3 && g.manufacturer == "Steinberg Media Technologies" && g.versionString == "1.0.0.1" && g.path == b.path)
    #expect(!g.isApple)
}

@Test func vst3CatalogListsFixtureFromOwnFolder() throws {
    let src = try #require(VST3Fixture.bundle)
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("vst3 plugins/sub")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let b = folder.appendingPathComponent("again-sampleaccurate.vst3")
    try FileManager.default.copyItem(at: src, to: b)

    let cat = PluginCatalog(directory: dir.appendingPathComponent("store"), folders: [], vst3Folders: [])
    cat.update { $0.folders = [dir.appendingPathComponent("vst3 plugins").path] }
    let list = cat.entries(refresh: true).filter { $0.format == .vst3 }
    #expect(list.count == 2)
    let e = try #require(list.first { $0.name == VST3Fixture.gainName })
    #expect(e.id == "vst3:C18D3C1E719E4E29924D3ECAA5E4DA18" && e.source == .folder && e.path == b.path)
    #expect(e.info != nil && e.problem == nil && e.canValidate && !e.canIsolate && !cat.isolated(e.id))
    #expect(!cat.menuList().contains { $0.id == e.id } && cat.inProcessReason(e.id) != nil)   // VST3 nur im Prozess: live aus
    cat.update { $0.allowInProcess = true }
    #expect(cat.menuList().contains { $0.id == e.id })
    cat.setEnabled(e.id, false)
    #expect(!cat.menuList().contains { $0.id == e.id })
    #expect(cat.unusableReason(e.id) != nil)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("store/plugin-opening.json").path))

    // Absturz beim Einlesen: Markierung des Bundles steht noch -> beim nächsten Start blockiert, Code nicht geladen
    cat.beginOpen(key: "bundle:" + b.path, name: b.lastPathComponent)
    let next = PluginCatalog(directory: dir.appendingPathComponent("store"), folders: [], vst3Folders: [])
    #expect(next.crashedLastRun?.key == "bundle:" + b.path)
    let blocked = try #require(next.entries(refresh: true).first { $0.id == "bundle:" + b.path })
    #expect(blocked.info == nil && blocked.format == .vst3 && next.blockReason(blocked.id) != nil)
    #expect(!next.menuList().contains { $0.isVST3 })
}

@Test func vst3ModuleInfoListsWithoutLoadingCode() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let b = dir.appendingPathComponent("Wobble.vst3")
    try FileManager.default.createDirectory(at: b.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    try Data("""
    { "Name": "Wobble", "Version": "2.1.0", "Factory Info": { "Vendor": "Someone" },
      "Classes": [
        { "CID": "0123456789ABCDEF0123456789ABCDEF", "Category": "Audio Module Class", "Name": "Wobble FX",
          "Sub Categories": ["Fx", "Modulation"], "Version": "2.1.0" },
        { "CID": "FEDCBA9876543210FEDCBA9876543210", "Category": "Audio Module Class", "Name": "Wobble Synth",
          "Sub Categories": ["Instrument"], "Version": "2.1.0" },
        { "CID": "00000000000000000000000000000001", "Category": "Component Controller Class", "Name": "Wobble Ctrl" }
      ] }
    """.utf8).write(to: b.appendingPathComponent("Contents/Resources/moduleinfo.json"))
    let c = try #require(PluginBundle.vst3Classes(b))
    #expect(c.map(\.name) == ["Wobble FX"])
    #expect(c[0].manufacturer == "Someone" && c[0].id == "vst3:0123456789ABCDEF0123456789ABCDEF")
    // kein Code im Bundle: Öffnen scheitert sauber mit Grund
    #expect(throws: (any Error).self) { _ = try PluginInstance(c[0], sampleRate: 44100) }
}

@Test func vst3GainRendersThroughCoreAndFollowsParameter() throws {
    let inst = try PluginInstance(try gainInfo(), sampleRate: 48000)
    #expect(inst.isVST3 && !inst.outOfProcess && inst.audioUnit == nil)
    // Bypass wird übersprungen: Regler 1 = Gain (normalisiert). Der Prozessor des Beispiels startet bei 0 (stumm),
    // der Controller übernimmt das beim Öffnen aus dessen Zustand
    #expect(inst.parameters.map(\.name) == ["Gain"])
    #expect(inst.knob(0) == 0)
    #expect(inst.latency == 0)
    let silent = throughCore(inst)
    #expect(silent.finite && silent.rms < 1e-4)
    inst.setKnob(0, 1)
    let unity = throughCore(inst)
    #expect(unity.finite && unity.rms > 0.1)
    inst.setKnob(0, 0.25)
    #expect(abs((inst.knob(0) ?? -1) - 0.25) < 1e-6)
    let quarter = throughCore(inst)
    print(String(format: "[vst3] gain 1: rms %.4f · gain 0.25: rms %.4f (%.3f)", unity.rms, quarter.rms, quarter.rms / unity.rms))
    #expect(quarter.finite && abs(quarter.rms / unity.rms - 0.25) < 0.02)
    // Änderung mitten im Lauf kommt im nächsten Block an
    inst.setKnob(0, 1)
    let late = throughCore(inst) { b in if b == 40 { inst.setKnob(0, 0.5) } }
    #expect(late.rms > quarter.rms && late.rms < unity.rms)
    #expect(inst.text(inst.parameters[0].id, 0.5).contains("0.5"))
}

@Test func vst3StateRoundTrip() throws {
    let info = try gainInfo()
    let a = try PluginInstance(info, sampleRate: 44100)
    a.setKnob(0, 0.3)
    _ = throughCore(a, fs: 44100, seconds: 0.2)   // Prozessor übernimmt den Wert
    let st = try #require(a.state)
    #expect(st.prefix(4) == Data("M7V3".utf8))
    let b = try PluginInstance(info, sampleRate: 44100)
    #expect(b.knob(0) == 0)
    b.state = st
    #expect(abs((b.knob(0) ?? 0) - 0.3) < 1e-6)
    let ra = throughCore(a, fs: 44100), rb = throughCore(b, fs: 44100)
    #expect(abs(ra.rms - rb.rms) < 1e-4)
    // kaputter Zustand: bleibt, wie es war
    b.state = Data("nope".utf8)
    #expect(abs((b.knob(0) ?? 0) - 0.3) < 1e-6)
}

@Test func vst3InstanceIsReleasedAfterHandoff() throws {
    weak var gone: PluginInstance?
    do {
        let inst = try PluginInstance(try gainInfo(), sampleRate: 44100)
        gone = inst
        _ = throughCore(inst, fs: 44100, seconds: 0.2)   // prüft Übergabe + Freigabe im Kern
    }
    #expect(gone == nil)   // geschlossen (VST3Thread ohne Haupt-Thread: sofort)
    // Modul bleibt geladen: erneut öffnen geht
    _ = try PluginInstance(try gainInfo(), sampleRate: 44100)
}

@Test func vst3HealResetsPluginAfterNaN() throws {
    let inst = try PluginInstance(try gainInfo(), sampleRate: 44100)
    let fs = 44100.0, frames = 44100
    let e = mdsp_create(fs)!
    defer { mdsp_destroy(e) }
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { l.deallocate(); r.deallocate() }
    for i in 0..<frames { l[i] = i < 600 ? .nan : 0.1; r[i] = l[i] }
    mdsp_set_track(e, 0, l, r, Int64(frames), fs, 0)
    mdsp_set_param(e, 0, MD_FX1_ASSIGN, 1)
    setSlotPlugin(e, 0, 0, inst.ptr)
    mdsp_set_fx(e, 0, MDFX_DRYWET, 1); mdsp_set_fx_slot(e, 0, 0, true, 1)
    mdsp_set_param(e, 0, MD_PLAYING, 1)
    let oL = UnsafeMutablePointer<Float>.allocate(capacity: 512), oR = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    defer { oL.deallocate(); oR.deallocate() }
    func block() {
        var ch: [UnsafeMutablePointer<Float>?] = [oL, oR]
        ch.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, 512) }
    }
    for _ in 0..<4 { block() }
    #expect(mdsp_fx_slot_needs_reset(e, 0, 0, 0))
    var done = false
    inst.reset { done = true }
    #expect(done)
    mdsp_fx_slot_reset_done(e, 0, 0, 0)
    #expect(!mdsp_fx_slot_needs_reset(e, 0, 0, 0))
    for _ in 0..<20 { block() }
    let last = Array(UnsafeBufferPointer(start: oL, count: 512))
    #expect(last.allSatisfy(\.isFinite) && last.contains { $0 != 0 })
    setSlotPlugin(e, 0, 0, nil)
    block()
}

@Test func vst3BogusBundleFailsCleanly() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var err = [CChar](repeating: 0, count: 256)
    // fehlt ganz
    #expect(mdvst3_scan(dir.appendingPathComponent("missing.vst3").path, nil, 0, &err, Int32(err.count)) == -1)
    #expect(!String(cString: err).isEmpty)
    // Bundle ohne Code
    let b = dir.appendingPathComponent("Empty.vst3")
    try FileManager.default.createDirectory(at: b.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Empty", "CFBundlePackageType": "BNDL"],
                                       format: .xml, options: 0).write(to: b.appendingPathComponent("Contents/Info.plist"))
    let r = PluginHost.vst3Classes(b)
    #expect(r.classes.isEmpty && r.error?.isEmpty == false)
    // Code ist kein Plugin (eine beliebige Binärdatei)
    try FileManager.default.copyItem(atPath: "/bin/echo", toPath: b.appendingPathComponent("Contents/MacOS/Empty").path)
    #expect(PluginHost.vst3Classes(b).error?.isEmpty == false)
    // Klasse gibt es nicht
    let real = try #require(VST3Fixture.bundle)
    #expect(mdvst3_open(real.path, "00000000000000000000000000000000", 44100, 512, &err, Int32(err.count)) == nil)
    #expect(String(cString: err) == "class not found in bundle")
    // im Katalog: Eintrag mit Grund, nicht ladbar
    let cat = PluginCatalog(directory: nil, folders: [], vst3Folders: [dir])
    let e = try #require(cat.entries(refresh: true).first { $0.id == "bundle:" + b.path })
    #expect(e.info == nil && e.problem != nil && e.format == .vst3)
    print("[vst3] kaputtes Bundle: \(e.problem ?? "")")
}

@Test func vst3SelfCheck() throws {
    let ok = PluginSelfCheck.run(try gainInfo())
    print("[vst3] Selbsttest:\n\(ok.log)")
    #expect(ok.passed)
    #expect(ok.log.contains("open ok") && ok.log.contains("closed"))
    let bad = PluginSelfCheck.run(.vst3(classID: "00000000000000000000000000000000", name: "x", vendor: "", version: "",
                                        path: "/nonexistent.vst3"))
    #expect(!bad.passed && bad.log.hasPrefix("open:"))
}

/// Ereignisse Audio-Thread → Steuer-Thread (performEdit/restartComponent während process()): Reihenfolge, Überlauf zählt
@Test func vst3HostEventRingKeepsOrderAndCountsDrops() {
    #expect(mdvst3_selftest_event_ring(200) == 0)     // passt, in Reihenfolge
    #expect(mdvst3_selftest_event_ring(256) == 0)     // voll, nichts verworfen
    #expect(mdvst3_selftest_event_ring(300) == 44)    // 256 Plätze: 44 verworfen, nie gewartet
    #expect(mdvst3_selftest_event_ring(1000) == 744)
}
