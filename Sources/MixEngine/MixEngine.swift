import AudioToolbox
import CoreAudio
import Foundation
import MixDSP

/// Die Audio-Engine: Swift-Fassade um den C++-Echtzeitkern (MixDSP) und einen einzigen CoreAudio-Ausgang.
/// Signalweg je Deck (alles im Kern, ein Render-Callback):
/// Track → Tempo (Varispeed oder Keylock/Time-Stretch) → Gain → EQ → Filter → FX 1 → FX 2 → Fader × Crossfader → Kanalpaar
public final class MixEngine: @unchecked Sendable {
    public static let deckCount = Int(MDSP_DECKS)
    public static let fxUnitCount = Int(MDSP_FX_UNITS)
    /// Delay-Zeiten in Beats (FXUnitState.delayIndex)
    public static let delayBeats: [Double] = [1.0 / 4, 1.0 / 2, 3.0 / 4, 1, 3.0 / 2, 2]
    /// Beat-FX in Beats: Gater-Periode, Roll-Länge, LFO-Periode (Flanger/Phaser)
    public static let gaterBeats: [Double] = [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2]
    public static let rollBeats: [Double] = [1.0 / 32, 1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1]
    public static let lfoBeats: [Double] = [1.0 / 2, 1, 2, 4, 8, 16, 32]

    let core: OpaquePointer
    /// Geräte-Queue: Start/Stop der Ausgabe, Listener des Geräts und der Geräteliste, Neuverbinden (nie Haupt-/Audio-Thread)
    let deviceQueue = DispatchQueue(label: "minos741.device", qos: .userInitiated)
    private static let queueKey = DispatchSpecificKey<Bool>()
    private let output: CoreAudioOutput
    private var players: [DeckPlayer] = []
    /// Rate, mit der Tracks dekodiert werden (= Geräterate beim Start; andere Raten gleicht der Kern aus)
    public let sampleRate: Double
    private let stateLock = NSLock()
    private var _lastError: String?
    private var _routing = Routing()
    private var _watch = OutputWatch()
    private var _lastReconnect: Double?
    /// Aufträge auf der Geräte-Queue, die die Oberfläche nicht abwartet (Öffnen, Schließen, Schlafen/Aufwachen)
    private var _busy = 0
    /// Nur Tests: ersetzt das Öffnen des Geräts (läuft auf der Geräte-Queue, ersetzt `CoreAudioOutput.start`)
    var openSeamForTest: ((AudioDeviceID?) throws -> Void)?
    /// Ein Auftrag für das Gerät läuft noch (Oberfläche: „Öffne Gerät …“)
    public var busy: Bool { stateLock.withLock { _busy > 0 } }
    public var lastError: String? { stateLock.withLock { _lastError } }
    public var routing: Routing { stateLock.withLock { _routing } }
    /// Zustand gegenüber dem Gerät (läuft, wartet auf das Gerät, Ruhezustand) und Zähler
    public var watch: OutputWatch { stateLock.withLock { _watch } }
    /// Dauer des letzten automatischen Neuverbindens: Gerät wieder da -> Ausgabe läuft (Sekunden)
    public var lastReconnect: Double? { stateLock.withLock { _lastReconnect } }
    public var running: Bool { output.running }
    public var deviceChannels: Int { output.channels }
    /// Puffergröße in Frames (nil = Gerätestandard)
    public var bufferFrames: UInt32?
    /// Gerät beim Start auf diese Rate stellen (nil = so lassen)
    public var deviceRate: Double?
    /// Geräte-ID der laufenden Ausgabe (0 = keine)
    public var outputDeviceID: AudioDeviceID { output.info.device }
    /// aktuelle Rate des Geräts
    public var outputRate: Double { output.deviceRate }
    /// Decks parallel rechnen: A im Audio-Thread, B–D auf eigenen Echtzeit-Threads in der Workgroup des Geräts, Summe danach.
    /// Gleiches Ergebnis wie seriell; umschaltbar im Betrieb (gilt ab dem nächsten Block)
    public var parallelDecks: Bool {
        get { mdsp_parallel(core) }
        set { mdsp_set_parallel(core, newValue) }
    }
    /// Diagnose der parallelen Decks: Worker gestartet, in der Workgroup des Geräts, mit Echtzeit-Policy
    public var parallelInfo: (workers: Int, joined: Int, realtime: Int) {
        var w: Int32 = 0, j: Int32 = 0, r: Int32 = 0
        mdsp_parallel_info(core, &w, &j, &r)
        return (Int(w), Int(j), Int(r))
    }

    /// Watchdog der parallelen Decks: Worker über der Frist (2 × Block) -> Deck in diesem Block still, danach seriell
    public struct ParallelWatchdog: Sendable, Equatable {
        /// Fristabläufe seit Start
        public var timeouts = 0
        /// wie lange der Worker beim letzten Fristablauf brauchte (bis fertig oder bis jetzt), Sekunden
        public var lastHang = 0.0
        /// seit dem letzten Fristablauf, Sekunden (nil = keiner)
        public var lastAgo: Double?
        /// Worker, die nach dem Fristablauf noch rechnen (ihr Deck bleibt still)
        public var stuck = 0
        public init() {}
    }
    public var parallelWatchdog: ParallelWatchdog {
        var w = MDParallelWatchdog()
        mdsp_parallel_watchdog(core, &w)
        var r = ParallelWatchdog()
        r.timeouts = Int(w.timeouts); r.lastHang = Double(w.lastHangNs) / 1e9; r.stuck = Int(w.stuck)
        if w.timeouts > 0 { r.lastAgo = Double(w.nowNs &- w.lastNs) / 1e9 }
        return r
    }
    /// gerechnete Blöcke seit Start (unabhängig von `takeLoad`)
    public var renderCount: UInt64 { mdsp_render_count(core) }
    /// nur Tests/Selbsttest: Worker `w` (0 = Deck B) schläft beim nächsten Auftrag (vor der Übernahme oder beim Rechnen)
    public func stallWorkerForTest(_ w: Int, seconds: Double, beforeTaking: Bool = false) {
        mdsp_debug_stall_worker(core, Int32(w), UInt32(max(0, seconds) * 1e6), beforeTaking)
    }

    /// Wird gerufen, wenn sich die Geräteliste oder das Standardgerät ändert (Geräte-Queue). Gerät weg/wieder da
    /// erledigt die Engine selbst; ob auf ein anderes Gerät gewechselt wird, entscheidet die Oberfläche
    public var onConfigurationChange: (@Sendable () -> Void)?
    /// Meldungen zur Ausgabe (Geräte-Queue): Gerät weg, wieder da, Rate/Puffer geändert
    public var onOutputEvent: (@Sendable (OutputEvent) -> Void)?

    public enum OutputEvent: Sendable, Equatable {
        case lost(device: String)
        /// wieder verbunden: `seconds` vom Wiederauftauchen bis zum laufenden Ausgang, `gap` ganze Pause
        case restored(device: String, seconds: Double, gap: Double)
        case rateChanged(from: Double, to: Double)
        case bufferChanged(from: UInt32, to: UInt32)
        case sleeping
    }

    public struct Routing: Equatable, Sendable {
        public var device: AudioDeviceID?
        public var firstChannel: [Int] = [0, 0, 0, 0]
        public init(device: AudioDeviceID? = nil, firstChannel: [Int] = [0, 0, 0, 0]) {
            self.device = device
            self.firstChannel = firstChannel
        }
    }

    /// `rate` = gewünschte Rate aus den Einstellungen (Kern rechnet damit), sonst die des Standardgeräts
    public init(rate: Double? = nil) {
        let dev = Self.defaultOutputDevice() ?? 0
        sampleRate = rate ?? Self.nominalRate(dev) ?? 44100
        core = mdsp_create(sampleRate)
        output = CoreAudioOutput(eventQueue: deviceQueue)
        players = (0..<Self.deckCount).map { DeckPlayer(core, $0) }
        deviceQueue.setSpecific(key: Self.queueKey, value: true)
        output.onDeviceEvent = { [weak self] e in self?.deviceEvent(e) }
        listenForDeviceChanges()
    }

    deinit {
        poll?.cancel()
        output.stop()
        mdsp_destroy(core)
    }

    public func player(_ d: Int) -> DeckPlayer { players[d] }

    // MARK: - Ausgabe

    public func start() { apply(routing) }
    /// bewusst anhalten (kein Neuverbinden)
    public func stop() {
        onQueue {
            output.stop()
            update(.stopped)
        }
    }

    /// Gerät und Kanalpaare setzen. Kanalwechsel ohne Neustart; nur ein Gerätewechsel (oder `restart`) startet die Ausgabe neu.
    /// Blockiert, bis die Ausgabe läuft (Geräte-Queue)
    public func apply(_ r: Routing, restart: Bool = false) {
        onQueue {
            let deviceChanged = restart || r.device != routing.device || !output.running
            stateLock.withLock { _routing = r }
            for d in 0..<Self.deckCount { mdsp_set_param(core, Int32(d), MD_OUT_CHANNEL, Float(r.firstChannel[d])) }
            guard deviceChanged else { return }
            update(.stopped)   // von Hand: ein Fehlschlag wartet nicht auf das alte Gerät
            open(r.device, setRate: deviceRate)
        }
    }

    /// Wie `apply`, kehrt aber sofort zurück (Oberfläche). Öffnen läuft auf der Geräte-Queue in derselben Reihenfolge;
    /// `busy` bis dahin, `completion` danach auf dem Hauptthread (dann gelten `running`, `routing`, `lastError`)
    public func applyAsync(_ r: Routing, restart: Bool = false, completion: @escaping @Sendable () -> Void = {}) {
        inBackground(completion) { self.apply(r, restart: restart) }
    }
    /// Wie `stop`, ohne zu warten (Oberfläche)
    public func stopAsync(completion: @escaping @Sendable () -> Void = {}) {
        inBackground(completion) { self.output.stop(); self.update(.stopped) }
    }

    /// Ruhezustand: Ausgabe anhalten, Decks bleiben, wie sie sind (laufen nach dem Aufwachen weiter)
    public func willSleep() { onQueue { act(.willSleep) } }
    /// aufgewacht: dasselbe Gerät neu öffnen, sonst darauf warten
    public func didWake() { onQueue { act(.didWake) } }
    /// Wie `willSleep`, ohne zu warten (Oberfläche)
    public func willSleepAsync(completion: @escaping @Sendable () -> Void = {}) { inBackground(completion) { self.act(.willSleep) } }
    /// Wie `didWake`, ohne zu warten (Oberfläche: Öffnen dauert bis ~0,5 s)
    public func didWakeAsync(completion: @escaping @Sendable () -> Void = {}) { inBackground(completion) { self.act(.didWake) } }

    /// Auftrag auf die Geräte-Queue legen; `busy` gilt bis er durch ist, `completion` läuft danach auf dem Hauptthread
    private func inBackground(_ completion: @escaping @Sendable () -> Void, _ work: @escaping () -> Void) {
        stateLock.withLock { _busy += 1 }
        deviceQueue.async {
            work()
            self.stateLock.withLock { self._busy -= 1 }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// nur Selbsttest: Ereignis einspeisen, als käme es vom Gerät (Gerät weg, Ratenwechsel)
    public func simulate(_ e: OutputWatch.Event) { onQueue { act(e) } }

    /// nur Selbsttest: Puffergröße am laufenden Gerät setzen (gilt nur für diesen Prozess) – der Listener meldet sie
    public func setDeviceBufferForTest(_ frames: UInt32) {
        var f = frames
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(output.info.device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &f)
    }

    private func onQueue(_ f: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true { f() } else { deviceQueue.sync(execute: f) }
    }

    @discardableResult
    private func update(_ e: OutputWatch.Event) -> OutputWatch.Action {
        let (a, wanted) = stateLock.withLock { (_watch.handle(e), _watch.wanted) }
        keepAwake(wanted)
        return a
    }

    /// Ausgabe öffnen (Geräte-Queue). `setRate` nur von Hand (Einstellungen) – automatisch wird die Geräterate nie gesetzt
    private func open(_ device: AudioDeviceID?, setRate: Double?) {
        do {
            if let seam = openSeamForTest { try seam(device) }
            else { try output.start(device: device, engine: core, engineRate: sampleRate, bufferFrames: bufferFrames, setDeviceRate: setRate) }
            let i = output.info
            cachePresentationLatency()
            stateLock.withLock { _lastError = nil; _routing.device = i.device }
            update(.started(uid: i.uid, rate: i.deviceRate, buffer: i.bufferFrameSize))
        } catch {
            stateLock.withLock { _lastError = error.localizedDescription }
            update(.startFailed)
        }
        pollWhileWaiting()
    }

    // MARK: - Gerät beobachten (Geräte-Queue)

    private var poll: DispatchSourceTimer?
    private var lostAt: UInt64 = 0, seenAt: UInt64 = 0
    private var rateWork: DispatchWorkItem?
    private var activity: NSObjectProtocol?

    private func deviceEvent(_ e: CoreAudioOutput.DeviceEvent) {
        switch e {
        case let .alive(on): act(.alive(on))
        case .rate:
            // das Gerät meldet beim Umschalten mehrmals: erst nach Ruhe neu öffnen
            rateWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, let r = Self.nominalRate(self.output.info.device) else { return }
                self.act(.rate(r))
            }
            rateWork = w
            deviceQueue.asyncAfter(deadline: .now() + 0.15, execute: w)
        case let .buffer(b): act(.buffer(b))
        }
    }

    /// Ereignis an die Zustandsmaschine, Aktion ausführen (Geräte-Queue)
    private func act(_ e: OutputWatch.Event) {
        let before = watch
        switch update(e) {
        case .none: break
        case .stop:
            let name = output.info.name
            output.stop()
            lostAt = mach_absolute_time(); seenAt = 0
            print(e == .willSleep ? "[audio] Ruhezustand: Ausgabe angehalten" : "[audio] \(name) weg: Ausgabe angehalten, warte auf das Gerät")
            onOutputEvent?(e == .willSleep ? .sleeping : .lost(device: name))
            pollWhileWaiting()
        case .reopen:
            if seenAt == 0 { seenAt = mach_absolute_time() }
            let w = watch, oldRate = before.rate
            guard let uid = w.uid, let dev = Self.device(uid: uid), Self.isAlive(dev) else {
                pollWhileWaiting()
                return
            }
            open(dev, setRate: nil)
            let now = watch, info = output.info
            guard now.phase == .running else { return }
            if case .rate = e {
                print(String(format: "[audio] Geräterate %.0f -> %.0f Hz: Ausgabe neu geöffnet (Kern bleibt %.0f Hz)", oldRate, info.deviceRate, sampleRate))
                onOutputEvent?(.rateChanged(from: oldRate, to: info.deviceRate))
            } else {
                let secs = Double(LinkSession.micros(hostTicks: mach_absolute_time() - seenAt)) / 1e6
                let gap = Double(LinkSession.micros(hostTicks: mach_absolute_time() - lostAt)) / 1e6
                stateLock.withLock { _lastReconnect = secs }
                print(String(format: "[audio] %@ wieder verbunden: %.0f ms nach dem Auftauchen, Pause %.1f s", info.name, secs * 1000, gap))
                onOutputEvent?(.restored(device: info.name, seconds: secs, gap: gap))
            }
            seenAt = 0
        case .reread:
            let old = before.buffer
            output.refresh()
            cachePresentationLatency()
            let i = output.info
            print(String(format: "[audio] Puffer %d -> %d Frames, Latenz %.1f ms", old, i.bufferFrameSize, i.outputLatency * 1000))
            onOutputEvent?(.bufferChanged(from: old, to: i.bufferFrameSize))
        }
    }

    /// solange auf das Gerät gewartet wird: alle 100 ms nachsehen (falls eine Meldung der Geräteliste ausbleibt)
    private func pollWhileWaiting() {
        guard watch.waiting else { poll?.cancel(); poll = nil; return }
        guard poll == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: deviceQueue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.checkPresent() }
        poll = t
        t.resume()
    }

    private func checkPresent() {
        let w = watch
        guard w.waiting else { pollWhileWaiting(); return }
        let present = w.uid.flatMap { Self.device(uid: $0) }.map { Self.isAlive($0) } ?? false
        if present { act(.present(true)) }
    }

    /// App Nap und Ruhezustand bei Leerlauf aus, solange die Ausgabe läuft oder auf das Gerät wartet
    private func keepAwake(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                                                            reason: "MINOS-741 audio output")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    /// Geräteliste und Standardgerät beobachten (Geräte-Queue): unser Gerät weg -> anhalten und warten,
    /// wieder da -> neu öffnen; danach die Oberfläche fragen (anderes Gerät gewählt, Standard gewechselt)
    private func listenForDeviceChanges() {
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, deviceQueue) { [weak self] _, _ in
                guard let self else { return }
                let w = self.watch
                if let uid = w.uid, w.phase == .running || w.waiting {
                    let dev = Self.device(uid: uid).flatMap { Self.isAlive($0) ? $0 : nil }
                    // neu eingesteckt, bevor das alte Gerät als weg gemeldet war: alte ID ist tot -> erst weg, dann neu öffnen
                    if w.phase == .running, let dev, dev != self.output.info.device { self.act(.present(false)) }
                    self.act(.present(dev != nil))
                }
                self.onConfigurationChange?()
            }
        }
    }

    // MARK: - Laden / Transport

    /// Track-Puffer an ein Deck geben. Liefert die Übergabe-Generation: den alten Puffer erst freigeben,
    /// wenn `trackConsumed(d, gen)` true ist (Audio-Thread hat den neuen übernommen).
    @discardableResult
    public func attach(_ audio: TrackAudio?, deck d: Int, startAt seconds: Double) -> UInt32 {
        players[d].reverse = false
        return mdsp_set_track(core, Int32(d), audio?.left, audio?.right, Int64(audio?.frames ?? 0), audio?.sampleRate ?? sampleRate, seconds)
    }

    public func trackConsumed(_ d: Int, _ gen: UInt32) -> Bool { mdsp_track_consumed(core, Int32(d), gen) }
    public func seek(_ d: Int, seconds: Double) { mdsp_seek(core, Int32(d), max(0, seconds)) }
    public func position(_ d: Int) -> Double { mdsp_position(core, Int32(d)) }
    /// Position, Zeit, zu der sie hörbar ist (mach_absolute_time-Basis, s) und die Geschwindigkeit, mit der der Kern
    /// rechnet (s je s, mit Vorzeichen; Nudge und Bend inklusive); nil ohne Stempel. Stempel wie clockStamp.
    public func positionStamp(_ d: Int) -> (pos: Double, at: Double, speed: Double)? {
        var p = 0.0, h: UInt64 = 0, v = 0.0
        guard mdsp_position_stamp(core, Int32(d), &p, &h, &v) else { return nil }
        return (p, LinkSession.seconds(hostTicks: h + LinkSession.hostTicks(seconds: presentationLatency)), v)
    }
    public func fluxPosition(_ d: Int) -> Double { mdsp_flux_position(core, Int32(d)) }
    /// Instant Double: Deck `d` übernimmt am nächsten Block die hörbare Position von `source` (sample-genau)
    public func follow(_ d: Int, deck source: Int) { mdsp_follow(core, Int32(d), Int32(source)) }
    /// Wellenform greifen (Vinyl): Ziel in Sekunden; `held` false = losgelassen, läuft aufs Ziel aus
    public func scratch(_ d: Int, seconds: Double, held: Bool) { mdsp_scratch(core, Int32(d), max(0, seconds), held) }

    public func setLoop(_ d: Int, active: Bool, start: Double, end: Double) {
        mdsp_set_loop(core, Int32(d), active, start, end)
    }

    /// Schnitt (nicht destruktiv): hörbar nur zwischen Start und Ende (Sekunden, Ende 0 = Track-Ende)
    public func setTrim(_ d: Int, start: Double, end: Double) { mdsp_set_trim(core, Int32(d), start, end) }

    public func loop(_ d: Int) -> (active: Bool, start: Double, end: Double) {
        var s = 0.0, e = 0.0
        let a = mdsp_loop(core, Int32(d), &s, &e)
        return (a, s, e)
    }

    /// Tempo-Faktor und Keylock. `idle` wird nicht gebraucht – der Kern rechnet stehende Decks gar nicht.
    public func setRate(_ d: Int, rate: Double, keylock: Bool, keyShift: Double, idle: Bool = false) {
        mdsp_set_param(core, Int32(d), MD_RATE, Float(rate))
        mdsp_set_param(core, Int32(d), MD_KEYLOCK, keylock ? 1 : 0)
        mdsp_set_param(core, Int32(d), MD_KEYSHIFT, Float(keyShift))
    }

    // MARK: - Mixer

    public func setEQ(_ d: Int, low: Double, mid: Double, high: Double, kill: Bool = true) {
        func g(_ v: Double) -> Float { Float(kill && v <= -25 ? -96 : v) }
        mdsp_set_param(core, Int32(d), MD_EQ_LOW, g(low))
        mdsp_set_param(core, Int32(d), MD_EQ_MID, g(mid))
        mdsp_set_param(core, Int32(d), MD_EQ_HIGH, g(high))
    }

    public func setGain(_ d: Int, db: Double) { mdsp_set_param(core, Int32(d), MD_GAIN_DB, Float(max(-24, min(24, db)))) }

    public func setChannelFilter(_ d: Int, _ v: Double, resonance: Double = 0.6) {
        mdsp_set_param(core, Int32(d), MD_FILTER, Float(v))
        mdsp_set_param(core, Int32(d), MD_FILTER_RES, Float(resonance))
    }

    public func setChannelVolume(_ d: Int, _ v: Double) { mdsp_set_param(core, Int32(d), MD_VOLUME, Float(max(0, min(1, v)))) }
    public func setMasterVolume(_ v: Double) { mdsp_set_master(core, Float(max(0, min(1, v)))) }

    // MARK: - Master-Clock

    public func setClockBPM(_ bpm: Double) { mdsp_clock_set_bpm(core, bpm) }
    public func setClockBeat(_ beat: Double) { mdsp_clock_set_beat(core, beat) }
    public var clockBeat: Double { mdsp_clock_beat(core) }
    /// Beat am Anfang des letzten Blocks + Host-Zeit, zu der er hörbar ist (mach_absolute_time).
    /// Kern-Stempel = HAL-Ausgabezeit des Blocks (der Puffer ist darin schon enthalten); dazu Geräte-, Sicherheits- und
    /// Stream-Latenz. Keylock braucht keinen Term: der Lesekopf läuft um die Stretch-Latenz voraus, die Clock folgt der
    /// hörbaren Position. Formel: docs/architecture.md (Link)
    public var clockStamp: (beat: Double, hostTime: UInt64)? {
        var b = 0.0, h: UInt64 = 0
        guard mdsp_clock_stamp(core, &b, &h) else { return nil }
        return (b, h + LinkSession.hostTicks(seconds: presentationLatency))
    }
    /// Ausgabelatenz ohne den Puffer: Geräte-, Sicherheits- und Stream-Latenz, Sekunden (lock-frei, s. cachePresentationLatency)
    public var presentationLatency: Double { mdsp_present_latency(core) }
    /// Aus dem Gerätezustand neu berechnen und im Kern ablegen; nur auf der Geräte-Queue nach Öffnen oder Neulesen
    private func cachePresentationLatency() {
        let i = output.info
        mdsp_set_present_latency(core, max(0, i.outputLatency - (i.deviceRate > 0 ? Double(i.bufferFrameSize) / i.deviceRate : 0)))
    }
    /// tatsächliche Puffergröße des Geräts (Frames)
    public var deviceBufferFrames: Int { Int(output.bufferFrameSize) }
    /// HAL-Ausgabezeit des letzten Blocks minus Callback-Beginn (Diagnose: etwa ein Puffer), Sekunden
    public var renderLead: Double { mdsp_render_lead() }
    /// Clock-Phase um `beats` verschieben, ohne Sprung im Bar-Zähler (Link-Nachführung)
    public func trimClock(_ beats: Double) { mdsp_clock_trim(core, beats) }
    public func setMetronome(on: Bool, volume: Double, firstChannel: Int) {
        mdsp_metronome(core, on, Float(volume), Int32(firstChannel))
    }

    // MARK: - Last / Latenz

    /// Messwerte für die Statusleiste: DSP-Last, Aussetzer, Latenz
    public struct RenderLoad: Sendable, Equatable {
        /// Rechenzeit ÷ Blockdauer seit dem letzten Abholen (Mittel, schwerster Block)
        public var average = 0.0
        public var peak = 0.0
        /// eigene Messung: Blöcke über 100 % Budget; Gerät: HAL-Überlastmeldungen (beide seit Start/Zurücksetzen)
        public var overloads = 0
        public var deviceOverloads = 0
        public var blocks = 0
        /// Ausgabelatenz (Puffer + Gerät + Sicherheit + Stream), Sekunden
        public var outputLatency = 0.0
        /// Keylock-Vorlauf (wird ausgeglichen), Sekunden
        public var keylockLatency = 0.0
        public var bufferFrames = 0
        public var sampleRate = 0.0
        public var running = false
        /// automatisch wieder verbunden (Gerät zurück, Aufwachen), Dauer des letzten (s), Raten-/Pufferwechsel von außen
        public var reconnects = 0
        public var lastReconnect: Double?
        public var rateChanges = 0
        public var bufferChanges = 0
        /// schwerster Render-Block seit dem letzten Abholen: Millisekunden je Abschnitt (A, B, C, D, Warten auf Worker,
        /// Summe + Master-Bus, Master/Begrenzung/Clock, Vorhören) und seine Blockgröße
        public var worstParts: [Double] = []
        public var worstFrames = 0
        public var worstTotalMs: Double { worstParts.reduce(0, +) }
        /// Watchdog der parallelen Decks (Fristabläufe seit Start, letzter)
        public var parallel = ParallelWatchdog()
        public init() {}
    }
    public static let worstPartNames = ["A", "B", "C", "D", "wait", "mix", "master", "pre"]

    /// Werte seit dem letzten Aufruf abholen (Mittel und Spitze beginnen danach neu) – höchstens ein Abholer
    public func takeLoad() -> RenderLoad {
        let l = mdsp_load_take()
        var r = RenderLoad()
        r.average = l.average; r.peak = l.peak; r.blocks = Int(l.blocks)
        r.overloads = Int(l.overloads); r.deviceOverloads = output.deviceOverloads
        r.outputLatency = output.outputLatency; r.keylockLatency = mdsp_keylock_latency(core)
        r.bufferFrames = Int(output.bufferFrameSize); r.sampleRate = output.deviceRate; r.running = output.running
        let w = watch
        r.reconnects = w.reconnects; r.lastReconnect = lastReconnect; r.rateChanges = w.rateChanges; r.bufferChanges = w.bufferChanges
        var parts = [UInt64](repeating: 0, count: 8), wf: UInt32 = 0
        mdsp_render_profile(core, &parts, 8, &wf)
        r.worstParts = parts.map { Double($0) / 1e6 }; r.worstFrames = Int(wf)
        r.parallel = parallelWatchdog
        return r
    }

    public func resetOverloads() {
        mdsp_load_reset_overloads()
        output.resetDeviceOverloads()
    }

    // MARK: - Pegel

    public final class Level: @unchecked Sendable {
        let e: OpaquePointer
        let d: Int32
        init(_ e: OpaquePointer, _ d: Int) { self.e = e; self.d = Int32(d) }
        public var rms: Float { var r: Float = 0, p: Float = 0; mdsp_levels(e, d, &r, &p); return r }
        public var peak: Float { var r: Float = 0, p: Float = 0; mdsp_levels(e, d, &r, &p); return p }
    }

    public lazy var levels: [Level] = (0..<Self.deckCount).map { Level(core, $0) }
}
