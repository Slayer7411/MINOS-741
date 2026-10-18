import AudioToolbox
import Foundation
import MixDSP

/// Effekt-Plugin: Audio Unit ("aufx"/"aumf", v2 oder v3 über die Bridge) oder eine Effekt-Klasse eines .vst3-Bundles
public struct PluginInfo: Identifiable, Hashable, Sendable {
    /// AU: "type:subtype:manu" als FourCC-Text, z. B. "aufx:mrev:appl" · VST3: "vst3:<Klassen-ID>"
    public let id: String
    public let name: String
    public let manufacturer: String
    public let type: UInt32, subtype: UInt32, manu: UInt32
    /// Komponenten-Version (0xMMMMmmbb)
    public var version: UInt32 = 0
    /// AUv3 (App-Erweiterung)
    public var isV3 = false
    /// Format (AUv2/AUv3/VST3)
    public var format: PluginFormat = .auv2
    /// VST3: Bundle und Klassen-ID (32 Hex-Zeichen), Version als Text
    public var path: String?
    public var classID: String?
    public var versionText: String?

    public init(id: String, name: String, manufacturer: String, type: UInt32, subtype: UInt32, manu: UInt32,
                version: UInt32 = 0, isV3: Bool = false) {
        self.id = id; self.name = name; self.manufacturer = manufacturer
        self.type = type; self.subtype = subtype; self.manu = manu
        self.version = version; self.isV3 = isV3
        format = isV3 ? .auv3 : .auv2
    }

    /// Effekt-Klasse eines .vst3-Bundles
    public static func vst3(classID: String, name: String, vendor: String, version: String, path: String) -> PluginInfo {
        var i = PluginInfo(id: "vst3:" + classID.uppercased(), name: name, manufacturer: vendor, type: 0, subtype: 0, manu: 0)
        i.format = .vst3; i.path = path; i.classID = classID.uppercased(); i.versionText = version
        return i
    }

    public var isVST3: Bool { format == .vst3 }
    /// von Apple (Hersteller "appl") – läuft immer im Prozess
    public var isApple: Bool { !isVST3 && manu == 0x6170706c }
    /// "1.6.0"
    public var versionString: String { versionText ?? PluginHost.versionString(version) }
}

/// Wo VST3-Aufrufe laufen, die das SDK dem "UI-Thread" vorbehält (Laden, Zustand, Controller, Ansicht, Reset).
/// Immer derselbe Thread: viele Plugins prüfen das. Die App setzt `useMain` (Haupt-Thread); Tests und die
/// Kommandozeile rechnen auf dem aufrufenden Thread.
public enum VST3Thread {
    nonisolated(unsafe) public static var useMain = false

    public static func sync<T>(_ f: () throws -> T) rethrows -> T {
        if !useMain || Thread.isMainThread { return try f() }
        return try DispatchQueue.main.sync(execute: f)
    }

    public static func async(_ f: @escaping () -> Void) {
        if !useMain { f(); return }
        DispatchQueue.main.async(execute: f)
    }
}

public enum PluginHost {
    /// alle installierten Effekt-Plugins, sortiert nach Hersteller und Name
    public static func installed() -> [PluginInfo] {
        var out: [PluginInfo] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            var desc = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0,
                                                 componentFlags: 0, componentFlagsMask: 0)
            var comp = AudioComponentFindNext(nil, &desc)
            while let c = comp {
                var d = AudioComponentDescription()
                if AudioComponentGetDescription(c, &d) == noErr {
                    var cf: Unmanaged<CFString>?
                    AudioComponentCopyName(c, &cf)
                    let full = cf?.takeRetainedValue() as String? ?? fourCC(d.componentSubType)
                    // "Hersteller: Name"
                    let parts = full.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let (manu, name) = parts.count == 2 ? (parts[0], parts[1]) : (fourCC(d.componentManufacturer), full)
                    var v: UInt32 = 0
                    AudioComponentGetVersion(c, &v)
                    out.append(PluginInfo(id: id(d.componentType, d.componentSubType, d.componentManufacturer), name: name,
                                          manufacturer: manu, type: d.componentType, subtype: d.componentSubType,
                                          manu: d.componentManufacturer, version: v,
                                          isV3: d.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0))
                }
                comp = AudioComponentFindNext(c, &desc)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
            .sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }

    /// Effekt-Klassen eines .vst3-Bundles (lädt den Code; das Modul bleibt geladen). Fehler als Text
    public static func vst3Classes(_ bundle: URL) -> (classes: [PluginInfo], error: String?) {
        var err = [CChar](repeating: 0, count: 512)
        var buf = [MDVST3Class](repeating: MDVST3Class(), count: 64)
        let n = VST3Thread.sync { mdvst3_scan(bundle.path, &buf, Int32(buf.count), &err, Int32(err.count)) }
        guard n >= 0 else { return ([], String(cString: err)) }
        let list = buf.prefix(Int(min(n, Int32(buf.count)))).map { c -> PluginInfo in
            PluginInfo.vst3(classID: cText(c.cid), name: cText(c.name), vendor: cText(c.vendor), version: cText(c.version),
                            path: bundle.path)
        }
        return (list, nil)
    }

    public static func id(_ t: UInt32, _ s: UInt32, _ m: UInt32) -> String { "\(fourCC(t)):\(fourCC(s)):\(fourCC(m))" }

    /// "aufx:mrev:appl" → Codes
    public static func codes(_ id: String) -> (UInt32, UInt32, UInt32)? {
        let p = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3, let t = code(p[0]), let s = code(p[1]), let m = code(p[2]) else { return nil }
        return (t, s, m)
    }

    public static func versionString(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xff).\(v & 0xff)" }

    public static func fourCC(_ v: UInt32) -> String {
        let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
        return String(bytes: b, encoding: .macOSRoman) ?? String(format: "%08x", v)
    }

    public static func code(_ s: String) -> UInt32? {
        guard let d = s.data(using: .macOSRoman), d.count == 4 else { return nil }
        return d.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// C-Zeichenkette aus einem festen char-Feld (Tupel) einer C-Struktur
func cText<T>(_ t: T) -> String {
    withUnsafeBytes(of: t) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

/// Eine geöffnete Plugin-Instanz (für genau eine FX-Unit × Deck). Schließt beim Freigeben –
/// die Engine hält sie, bis der Audio-Thread sie nicht mehr rechnet.
/// AU: Parameter mit eigenem Bereich (min…max). VST3: normalisiert (0…1), Werte aus einem eigenen Spiegel
/// (thread-sicher, ohne den Controller auf fremden Threads zu fragen).
public final class PluginInstance: @unchecked Sendable {
    public struct Parameter: Sendable, Equatable {
        public let id: AudioUnitParameterID
        public let name: String
        public let min: Float, max: Float, defaultValue: Float
        /// Einheit, Stufen (0 = stufenlos, 1 = Schalter, n = n + 1 Stufen)
        public var units = ""
        public var steps = 0
        /// Gruppe (AU: Clump, VST3: Unit), leer = keine
        public var group = ""
        /// Namen der Stufen (Schalter, Liste)
        public var valueNames: [String] = []
        /// Reglerkurve (AU-Display-Flags)
        public var curve = ParamCurve.linear
    }

    public let info: PluginInfo
    let ptr: OpaquePointer
    /// AU-Instanz (nil bei VST3)
    public let audioUnit: AudioUnit?
    /// läuft isoliert in einem Systemdienst (Absturz trifft nur den Dienst, nicht MINOS-741)
    public let outOfProcess: Bool
    public let sampleRate: Double
    /// beschreibbare Parameter (AU: globaler Scope; VST3: ohne nur-lesen, versteckt, Bypass, Programmwechsel)
    public private(set) lazy var parameters: [Parameter] = readParameters()
    public var isVST3: Bool { audioUnit == nil }

    /// VST3: Werte-Spiegel, Beobachter, Ansicht
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var ptr: OpaquePointer?
        var ids: [UInt32] = []
        var values: [UInt32: Double] = [:]
        var observer: ((UInt32, Float) -> Void)?
        var resize: ((Int, Int) -> Void)?

        /// alle Werte vom Controller neu lesen (VST3Thread); geänderte an den Beobachter
        func refresh() {
            guard let p = ptr else { return }
            let fresh = Dictionary(uniqueKeysWithValues: ids.map { ($0, mdvst3_param_get(p, $0)) })
            let (old, f) = lock.withLock { () -> ([UInt32: Double], ((UInt32, Float) -> Void)?) in
                defer { values = fresh }
                return (values, observer)
            }
            guard let f else { return }
            for (id, v) in fresh where old[id] != v { f(id, Float(v)) }
        }
    }
    private let shared = Shared()
    private var vst3Params: [Parameter] = []

    /// öffnen (blockiert bis zu `timeout` s – nie auf dem Audio-Thread aufrufen). `outOfProcess`: über
    /// AudioComponentInstantiate mit kAudioComponentInstantiation_LoadOutOfProcess (v2 und v3, macOS 11+).
    /// VST3 läuft immer im Prozess (auf VST3Thread).
    public init(_ info: PluginInfo, sampleRate: Double, outOfProcess: Bool = false, timeout: Double = 10) throws {
        self.info = info
        self.sampleRate = sampleRate
        var err = [CChar](repeating: 0, count: 512)
        let fail = { (why: String) in
            NSError(domain: "minos741.plugin", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(info.name): \(why)"])
        }
        if info.isVST3 {
            guard let path = info.path, let cid = info.classID else { throw fail("no bundle") }
            self.outOfProcess = false
            audioUnit = nil
            let opened = VST3Thread.sync { mdvst3_open(path, cid, sampleRate, UInt32(MDSP_MAX_FRAMES), &err, Int32(err.count)) }
            guard let p = opened else { throw fail(String(cString: err)) }
            ptr = p
            VST3Thread.sync { setupVST3() }
            return
        }
        self.outOfProcess = outOfProcess
        let opened: OpaquePointer?
        if outOfProcess {
            let au = try Self.instantiate(info, options: .loadOutOfProcess, timeout: timeout, fail: fail)
            opened = mdplug_wrap(UnsafeMutableRawPointer(au), sampleRate, UInt32(MDSP_MAX_FRAMES), &err, Int32(err.count))
        } else {
            opened = mdplug_open(info.type, info.subtype, info.manu, sampleRate, UInt32(MDSP_MAX_FRAMES), &err, Int32(err.count))
        }
        guard let p = opened, let raw = mdplug_audio_unit(p) else { throw fail(String(cString: err)) }
        ptr = p
        audioUnit = AudioUnit(OpaquePointer(raw))
    }

    /// asynchron anlegen und auf das Ergebnis warten; kommt es nach dem Zeitlimit, wird es gleich wieder geschlossen
    private static func instantiate(_ info: PluginInfo, options: AudioComponentInstantiationOptions, timeout: Double,
                                    fail: (String) -> NSError) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: info.type, componentSubType: info.subtype,
                                             componentManufacturer: info.manu, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw fail("audio unit not installed") }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var unit: AudioUnit?
            var status: OSStatus = noErr
            var abandoned = false
        }
        let box = Box(), done = DispatchSemaphore(value: 0)
        AudioComponentInstantiate(comp, options) { unit, st in
            box.lock.lock(); defer { box.lock.unlock() }
            if box.abandoned { if let unit { AudioComponentInstanceDispose(unit) }; return }
            box.unit = unit; box.status = st
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            box.lock.lock(); defer { box.lock.unlock() }
            if let u = box.unit { return u }   // genau an der Grenze fertig geworden
            box.abandoned = true
            throw fail("instantiate timed out")
        }
        guard box.status == noErr, let u = box.unit else { throw fail("instance failed (\(box.status))") }
        return u
    }

    /// Latenz des Plugins in Sekunden (AU: kAudioUnitProperty_Latency, VST3: getLatencySamples) – nicht ausgeglichen
    public var latency: Double {
        guard let au = audioUnit else { return Double(mdvst3_latency(ptr)) / sampleRate }
        var v: Float64 = 0
        var s = UInt32(MemoryLayout<Float64>.size)
        return AudioUnitGetProperty(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &v, &s) == noErr ? v : 0
    }

    /// Nachklingzeit laut Plugin in Sekunden (nil = endlos)
    public var tail: Double? {
        let t = isVST3 ? mdvst3_tail(ptr) : 0
        return t == UInt32.max ? nil : Double(t) / sampleRate
    }

    /// vom Kern nicht gerechnete Blöcke (Fehler, Zeitüberschreitung des Dienstes) und Sekunden, die zuletzt am Stück fehlschlugen
    public var renderFailures: (blocks: UInt64, seconds: Double) {
        var b: UInt64 = 0, f: UInt64 = 0
        mdplug_failures(ptr, &b, &f)
        return (b, Double(f) / sampleRate)
    }

    /// einen Block durch das Plugin rechnen (Messungen, Tests; im Betrieb rechnet der Kern)
    public func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        mdplug_process(ptr, l, r, Int32(n))
    }

    /// VST3: Ereignisse des Audio-Threads abarbeiten (Zuhörer, Umbau). Vom Steuer-Thread, außerhalb der Sperre des Controllers
    func drainHostEvents() {
        guard isVST3 else { return }
        mdvst3_drain_events(ptr)
    }

    deinit {
        stopObserving()
        if isVST3 {
            let p = ptr, keep = shared
            VST3Thread.async {
                mdvst3_set_listener(p, nil, nil)
                mdplug_close(p)
                _ = keep
            }
        } else {
            mdplug_close(ptr)
        }
    }

    private var listener: AUParameterListenerRef?

    /// Parameteränderungen (Plugin-Fenster, Automation) melden – auf `queue`, AU höchstens alle 30 ms je Parameter
    public func observe(on queue: DispatchQueue, _ f: @escaping @Sendable (AudioUnitParameterID, Float) -> Void) {
        stopObserving()
        guard let au = audioUnit else {
            shared.lock.withLock { shared.observer = { id, v in queue.async { f(id, v) } } }
            return
        }
        var l: AUParameterListenerRef?
        guard AUListenerCreateWithDispatchQueue(&l, 0.03, queue, { _, p, v in f(p.pointee.mParameterID, v) }) == noErr,
              let l else { return }
        for p in parameters {
            var ap = AudioUnitParameter(mAudioUnit: au, mParameterID: p.id, mScope: kAudioUnitScope_Global, mElement: 0)
            AUListenerAddParameter(l, nil, &ap)
        }
        listener = l
    }

    public func stopObserving() {
        shared.lock.withLock { shared.observer = nil }
        if let l = listener { AUListenerDispose(l); listener = nil }
    }

    /// Zustand löschen (Hall, Delay). VST3: auf VST3Thread, `done` danach
    public func reset(_ done: @escaping () -> Void = {}) {
        if isVST3 {
            let p = ptr, keep = shared
            VST3Thread.async { mdplug_reset(p); _ = keep; done() }
        } else {
            mdplug_reset(ptr); done()
        }
    }

    private func readParameters() -> [Parameter] {
        guard let au = audioUnit else { return vst3Params }
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(au, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, nil) == noErr,
              size > 0 else { return [] }
        var ids = [AudioUnitParameterID](repeating: 0, count: Int(size) / MemoryLayout<AudioUnitParameterID>.size)
        guard AudioUnitGetProperty(au, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &ids, &size) == noErr else { return [] }
        var clumps: [UInt32: String] = [:]
        return ids.compactMap { id in
            var pi = AudioUnitParameterInfo()
            var s = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            guard AudioUnitGetProperty(au, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &pi, &s) == noErr,
                  pi.flags.contains(.flag_IsWritable) else { return nil }
            var name = ""
            if pi.flags.contains(.flag_HasCFNameString), let cf = pi.cfNameString {
                name = cf.takeUnretainedValue() as String
                if pi.flags.contains(.flag_CFNameRelease) { cf.release() }
            } else {
                name = withUnsafeBytes(of: pi.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            }
            var p = Parameter(id: id, name: name, min: pi.minValue, max: pi.maxValue, defaultValue: pi.defaultValue)
            p.units = Self.unitText(pi)
            switch pi.unit {
            case .boolean: p.steps = 1
            case .indexed: p.steps = Swift.max(1, Int((pi.maxValue - pi.minValue).rounded()))
            default: break
            }
            if p.steps > 0, pi.flags.contains(.flag_ValuesHaveStrings) { p.valueNames = Self.valueStrings(au, id, count: p.steps + 1) }
            let display = pi.flags.rawValue & AudioUnitParameterOptions.flag_DisplayMask.rawValue
            p.curve = switch display {
                case AudioUnitParameterOptions.flag_DisplayLogarithmic.rawValue: .logarithmic
                case AudioUnitParameterOptions.flag_DisplaySquareRoot.rawValue: .squareRoot
                case AudioUnitParameterOptions.flag_DisplaySquared.rawValue: .squared
                case AudioUnitParameterOptions.flag_DisplayCubeRoot.rawValue: .cubeRoot
                case AudioUnitParameterOptions.flag_DisplayCubed.rawValue: .cubed
                default: .linear
            }
            if pi.flags.contains(.flag_HasClump) {
                if clumps[pi.clumpID] == nil { clumps[pi.clumpID] = Self.clumpName(au, pi.clumpID) }
                p.group = clumps[pi.clumpID] ?? ""
            }
            return p
        }
    }

    /// Einheit eines AU-Parameters als Text
    private static func unitText(_ pi: AudioUnitParameterInfo) -> String {
        switch pi.unit {
        case .percent, .equalPowerCrossfade: "%"
        case .seconds: "s"
        case .milliseconds: "ms"
        case .hertz: "Hz"
        case .decibels: "dB"
        case .cents: "ct"
        case .relativeSemiTones: "st"
        case .BPM: "BPM"
        case .beats: "beats"
        case .degrees, .phase: "°"
        case .octaves: "oct"
        case .meters: "m"
        case .sampleFrames: "smp"
        case .rate: "×"
        case .customUnit: pi.unitName?.takeUnretainedValue() as String? ?? ""
        default: ""
        }
    }

    /// Namen der Stufen eines Listen-Parameters
    private static func valueStrings(_ au: AudioUnit, _ id: AudioUnitParameterID, count: Int) -> [String] {
        var ref: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioUnitGetProperty(au, kAudioUnitProperty_ParameterValueStrings, kAudioUnitScope_Global, id, &ref, &size) == noErr,
              let list = ref?.takeRetainedValue() as? [String], list.count >= count else { return [] }
        return Array(list.prefix(count))
    }

    /// Name einer Parameter-Gruppe (Clump)
    private static func clumpName(_ au: AudioUnit, _ clump: UInt32) -> String? {
        var info = AudioUnitParameterNameInfo(inID: clump, inDesiredLength: Int32(kAudioUnitParameterName_Full), outName: nil)
        var size = UInt32(MemoryLayout<AudioUnitParameterNameInfo>.size)
        guard AudioUnitGetProperty(au, kAudioUnitProperty_ParameterClumpName, kAudioUnitScope_Global, 0, &info, &size) == noErr,
              let n = info.outName?.takeRetainedValue() else { return nil }
        return n as String
    }

    // MARK: VST3 (auf VST3Thread)

    /// Parameter lesen, Werte spiegeln, Änderungen aus dem Plugin (eigene Ansicht) annehmen
    private func setupVST3() {
        var list: [Parameter] = []
        var info = MDVST3Param()
        var units: [Int32: String] = [:]
        var buf = [CChar](repeating: 0, count: 128)
        for i in 0..<mdvst3_param_count(ptr) where mdvst3_param_info(ptr, i, &info) {
            let skip = Int32(MDVST3_PARAM_READ_ONLY | MDVST3_PARAM_HIDDEN | MDVST3_PARAM_BYPASS | MDVST3_PARAM_PROGRAM_CHANGE)
            guard info.flags & skip == 0 else { continue }
            var p = Parameter(id: info.id, name: cText(info.title), min: 0, max: 1, defaultValue: Float(info.defaultValue),
                              units: cText(info.units), steps: Int(info.stepCount))
            // Stufen mit Namen (Schalter, Listen bis 64 Einträge); Unit ≠ Wurzel = Gruppe
            if p.steps > 0, p.steps <= 64 {
                p.valueNames = (0...p.steps).map { k in
                    mdvst3_param_text(ptr, info.id, Double(k) / Double(p.steps), &buf, Int32(buf.count))
                        ? String(cString: buf) : String(k)
                }
            }
            if info.unitId > 0 {
                if units[info.unitId] == nil {
                    units[info.unitId] = mdvst3_unit_name(ptr, info.unitId, &buf, Int32(buf.count)) ? String(cString: buf) : ""
                }
                p.group = units[info.unitId] ?? ""
            }
            list.append(p)
        }
        vst3Params = list
        shared.ptr = ptr
        shared.ids = list.map(\.id)
        shared.refresh()
        let ctx = Unmanaged.passUnretained(shared).toOpaque()
        mdvst3_set_listener(ptr, { ctx, id, v in
            guard let ctx else { return }
            let s = Unmanaged<Shared>.fromOpaque(ctx).takeUnretainedValue()
            if id == MDVST3_ALL_PARAMS { s.refresh(); return }
            let f = s.lock.withLock { () -> ((UInt32, Float) -> Void)? in s.values[id] = v; return s.observer }
            f?(id, Float(v))
        }, ctx)
    }

    /// Wert eines Parameters (AU: min…max, VST3: 0…1)
    public func value(_ id: AudioUnitParameterID) -> Float {
        guard let au = audioUnit else { return Float(shared.lock.withLock { shared.values[id] } ?? 0) }
        if outOfProcess { paramQueue.sync {} }   // erst die offenen Setzungen (Lesen nach Schreiben)
        var v: AudioUnitParameterValue = 0
        AudioUnitGetParameter(au, id, kAudioUnitScope_Global, 0, &v)
        return v
    }

    /// setzen und Zuhörer (Plugin-Fenster) benachrichtigen. VST3: sofort an den Prozessor, Controller auf VST3Thread
    public func set(_ id: AudioUnitParameterID, _ v: Float) {
        guard let au = audioUnit else {
            let x = Double(Swift.max(0, Swift.min(1, v)))
            shared.lock.withLock { shared.values[id] = x }
            mdvst3_param_send(ptr, id, x)
            VST3Thread.async { [self] in mdvst3_param_set(ptr, id, x) }
            return
        }
        var p = AudioUnitParameter(mAudioUnit: au, mParameterID: id, mScope: kAudioUnitScope_Global, mElement: 0)
        // isoliert: Aufruf geht an den Dienst – hängt der, darf der Steuer-Thread (unter der Sperre) nicht warten.
        // Eigene serielle Queue: Reihenfolge bleibt
        guard outOfProcess else { AUParameterSet(nil, nil, &p, v, 0); return }
        paramQueue.async { [self] in   // hält die Instanz, bis gesetzt ist (deinit schließt sie)
            guard let au = audioUnit else { return }
            var q = AudioUnitParameter(mAudioUnit: au, mParameterID: id, mScope: kAudioUnitScope_Global, mElement: 0)
            AUParameterSet(nil, nil, &q, v, 0)
        }
    }
    private let paramQueue = DispatchQueue(label: "minos741.plugin-params", qos: .userInitiated)

    /// Anzeige-Text eines Werts (VST3: vom Plugin, AU: Zahl)
    public func text(_ id: AudioUnitParameterID, _ v: Float) -> String {
        guard isVST3 else { return String(format: "%.2f", v) }
        var buf = [CChar](repeating: 0, count: 128)
        let ok = VST3Thread.sync { mdvst3_param_text(ptr, id, Double(v), &buf, Int32(buf.count)) }
        return ok ? String(cString: buf) : String(format: "%.2f", v)
    }

    /// Regler 0…1 auf den i-ten beschreibbaren Parameter (min…max)
    public func setKnob(_ i: Int, _ v: Double) {
        guard i < parameters.count else { return }
        let p = parameters[i]
        set(p.id, p.min + Float(max(0, min(1, v))) * (p.max - p.min))
    }

    /// Stellung des i-ten Parameters als 0…1
    public func knob(_ i: Int) -> Double? {
        guard i < parameters.count else { return nil }
        let p = parameters[i]
        return p.max > p.min ? Double((value(p.id) - p.min) / (p.max - p.min)) : nil
    }

    /// kompletter Zustand: AU = ClassInfo als Binär-Plist, VST3 = Komponente + Controller (eigener Container)
    public var state: Data? {
        get {
            guard let au = audioUnit else {
                return VST3Thread.sync {
                    var out: UnsafeMutablePointer<UInt8>?
                    let n = mdvst3_get_state(ptr, &out)
                    guard n > 0, let out else { return nil }
                    defer { free(out) }
                    return Data(bytes: out, count: n)
                }
            }
            var ref: Unmanaged<CFPropertyList>?
            var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
            guard AudioUnitGetProperty(au, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &ref, &size) == noErr,
                  let plist = ref?.takeRetainedValue() else { return nil }
            return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        }
        set {
            guard let d = newValue else { return }
            guard let au = audioUnit else {
                VST3Thread.sync {
                    let ok = d.withUnsafeBytes { b in mdvst3_set_state(ptr, b.bindMemory(to: UInt8.self).baseAddress, d.count) }
                    if ok { shared.refresh() }
                }
                return
            }
            guard let obj = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) else { return }
            let plist = obj as CFPropertyList
            // Wert der Eigenschaft ist der CFPropertyListRef selbst
            var ref: UnsafeRawPointer? = UnsafeRawPointer(Unmanaged.passUnretained(plist).toOpaque())
            let st = withExtendedLifetime(plist) {
                AudioUnitSetProperty(au, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0,
                                     &ref, UInt32(MemoryLayout<UnsafeRawPointer>.size))
            }
            guard st == noErr else { return }
            // Ansichten neu einlesen lassen
            var any = AudioUnitParameter(mAudioUnit: au, mParameterID: kAUParameterListener_AnyParameter,
                                         mScope: kAudioUnitScope_Global, mElement: 0)
            AUParameterListenerNotify(nil, nil, &any)
        }
    }

    // MARK: VST3-Ansicht (Haupt-Thread)

    /// eigene Ansicht des Plugins in die NSView `view` (Zeiger) hängen; Größe oder nil (keine eigene Ansicht).
    /// `resize`: das Plugin möchte eine andere Größe
    public func openEditor(in view: UnsafeMutableRawPointer, resize: @escaping (Int, Int) -> Void) -> (width: Int, height: Int)? {
        guard isVST3 else { return nil }
        shared.lock.withLock { shared.resize = resize }
        var w: Int32 = 0, h: Int32 = 0
        let ctx = Unmanaged.passUnretained(shared).toOpaque()
        let ok = mdvst3_editor_open(ptr, view, &w, &h, { ctx, w, h in
            guard let ctx else { return }
            let s = Unmanaged<Shared>.fromOpaque(ctx).takeUnretainedValue()
            let f = s.lock.withLock { s.resize }
            f?(Int(w), Int(h))
        }, ctx)
        guard ok else { shared.lock.withLock { shared.resize = nil }; return nil }
        return (Int(w > 0 ? w : 420), Int(h > 0 ? h : 300))
    }

    public var editorResizable: Bool { isVST3 && mdvst3_editor_resizable(ptr) }

    /// Fenster wurde gezogen: neue Größe an die Ansicht, liefert die angenommene
    public func setEditorSize(_ w: Int, _ h: Int) -> (width: Int, height: Int)? {
        var cw = Int32(w), ch = Int32(h)
        return mdvst3_editor_set_size(ptr, &cw, &ch) ? (Int(cw), Int(ch)) : nil
    }

    public func closeEditor() {
        guard isVST3 else { return }
        mdvst3_editor_close(ptr)
        shared.lock.withLock { shared.resize = nil }
    }
}
