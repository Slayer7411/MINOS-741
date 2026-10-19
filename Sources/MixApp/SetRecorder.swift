import AppKit
import AVFoundation
import SwiftUI
import MixCore
import MixEngine

/// Quelle der Aufnahme (⌘, -> AUDIO -> Aufnahme)
enum RecordSource: String, CaseIterable, Codable, Identifiable {
    /// extern -> Eingang vom Pult, intern -> interner Master
    case auto, input, master
    var id: String { rawValue }
}

/// Aufnahme: Quelle, Eingang (Gerät + Paar), Ordner, Format, Eingangspegel ohne Aufnahme
struct RecordPrefs: Codable, Equatable {
    var source = RecordSource.auto
    /// Eingangsgerät (UID), "" = das Ausgabegerät
    var inputUID = ""
    /// erster Kanal des Eingangspaars (0-basiert)
    var inputFirstChannel = 0
    /// Zielordner, "" = ~/Music/MINOS-741/Recordings
    var folder = ""
    var format = RecordingFile.Kind.alac
    /// Pegel des Eingangs zeigen, auch ohne Aufnahme (Routing am Pult prüfen)
    var showInputLevel = false

    static let defaultFolder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MINOS-741").appendingPathComponent("Recordings")
    var folderURL: URL { folder.isEmpty ? Self.defaultFolder : URL(fileURLWithPath: folder) }
}

extension RecordingFile.Kind {
    var title: String {
        switch self {
        case .alac: String(localized: "Apple Lossless (.m4a)")
        case .wav: String(localized: "WAV 24 Bit")
        case .aiff: String(localized: "AIFF 24 Bit")
        }
    }
}

/// Set-Aufnahme: interner Master (Abgriff im Kern) oder Eingang vom Pult (eigenes Eingangs-AUHAL) -> Ring -> Datei auf
/// eigener Queue; Tracklist (.txt, .cue) aus der History, alle 60 s und beim Stopp. Pegel für REC-Anzeigen.
@MainActor @Observable
final class SetRecorder {
    enum Active: Equatable {
        case master(pair: Int)
        case input(name: String, pair: Int, rate: Double)
        var label: String {
            switch self {
            case let .master(p): String(localized: "Interner Master") + " \(p + 1)/\(p + 2)"
            case let .input(n, p, _): "\(n) \(p + 1)/\(p + 2)"
            }
        }
    }

    private(set) var recording = false
    private(set) var startedAt: Date?
    private(set) var url: URL?
    private(set) var active: Active?
    /// Eingang läuft nur für die Pegelanzeige
    private(set) var monitoring = false
    /// verworfene Blöcke der laufenden Aufnahme (Ring voll)
    private(set) var dropouts = 0

    /// Pegel L/R mit Halten (Anzeigen lesen ohne Beobachtung)
    struct Level { var l: Float = 0, r: Float = 0, holdL: Float = 0, holdR: Float = 0, clip: Date? }
    @ObservationIgnored private(set) var level = Level()
    @ObservationIgnored private var holdAt: (Date, Date) = (.distantPast, .distantPast)

    @ObservationIgnored weak var mix: MixModel?
    /// History der laufenden Sitzung (gesetzt vom HistoryStore)
    @ObservationIgnored weak var history: HistoryStore?
    /// Selbsttest: Ordner statt der Einstellung
    @ObservationIgnored var folderOverride: URL?
    /// Selbsttest: Quelle fest (Master auf 1/2 unabhängig vom gespeicherten Mixer-Modus)
    @ObservationIgnored var testSource: RecordSource?

    @ObservationIgnored private var masterRing: RecordRing?
    @ObservationIgnored private var inputRing: RecordRing?
    @ObservationIgnored private let input = CoreAudioInput()
    @ObservationIgnored private var sink: RecordSink?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var listTimer: Timer?
    @ObservationIgnored private var playingAtStart: Set<String> = []
    @ObservationIgnored private var stopping = false
    /// Ordner und Dateiname werden im Hintergrund vorbereitet (Start läuft danach)
    @ObservationIgnored private(set) var preparing = false

    init() {
        input.onEvent = { [weak self] e in
            Task { @MainActor in self?.inputEvent(e) }
        }
    }

    // MARK: Quelle

    /// gewählte Quelle (auto: extern -> Eingang, intern -> Master)
    func source(_ mix: MixModel) -> RecordSource {
        let s = mix.prefs.record.source
        return s == .auto ? (mix.mixerMode == .external ? .input : .master) : s
    }

    /// Eingangsgerät: gewählte UID, sonst das Ausgabegerät
    func inputDevice(_ mix: MixModel) -> AudioDeviceID? {
        let uid = mix.prefs.record.inputUID
        if !uid.isEmpty { return MixEngine.inputDevice(uid: uid) }
        guard let d = mix.engine.routing.device ?? MixEngine.defaultOutputDevice(), MixEngine.inputChannels(d) > 0 else { return nil }
        return d
    }

    // MARK: Start / Stopp

    func toggle() { recording ? stop() : start() }

    /// Aufnahme starten; Fehler -> Statuszeile, keine Aufnahme
    func start() {
        guard let mix, !recording, !stopping, !preparing else { return }
        let src = testSource ?? source(mix)
        if src == .input {
            // erst das Gerät (ohne Gerät keine Rückfrage nach dem Zugriff), dann der Zugriff auf Eingänge
            guard inputDevice(mix) != nil else { fail(String(localized: "Aufnahme: Eingangsgerät nicht da oder ohne Eingänge")); return }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                    Task { @MainActor in
                        if ok { self?.start() } else { self?.fail(String(localized: "Kein Zugriff auf Audio-Eingänge (Systemeinstellungen → Datenschutz → Mikrofon)")) }
                    }
                }
                return
            default:
                fail(String(localized: "Kein Zugriff auf Audio-Eingänge (Systemeinstellungen → Datenschutz → Mikrofon)"))
                return
            }
        }
        let now = Date()
        let folder = folderOverride ?? mix.prefs.record.folderURL
        let ext = mix.prefs.record.format.ext
        // Ordner anlegen und freien Namen suchen im Hintergrund (ein Cloud-Ordner kann dabei hängen), dann beginnen
        preparing = true
        Task {
            do {
                let stem = try await Task.detached { try SetRecorder.freeStem(folder, now, ext: ext) }.value
                self.preparing = false
                try self.begin(mix, src, now: now, stem: stem)
            } catch {
                self.preparing = false
                self.fail(error.localizedDescription)
            }
        }
    }

    /// freier Stamm im Ordner (legt ihn an); nie auf dem Hauptthread aufrufen
    nonisolated static func freeStem(_ folder: URL, _ now: Date, ext: String) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return RecordingName.free(now, ext: ext) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    private struct Failure: LocalizedError { let errorDescription: String? }

    private func begin(_ mix: MixModel, _ src: RecordSource, now: Date, stem: String) throws {
        let prefs = mix.prefs.record
        let ring: RecordRing, rate: Double, act: Active
        if src == .master {
            guard mix.mixerMode == .internalMixer || testSource != nil else {
                throw Failure(errorDescription: String(localized: "Interner Master gibt es nur im internen Mixer – Quelle „Eingang vom Pult“ wählen"))
            }
            guard mix.engine.running else { throw Failure(errorDescription: String(localized: "Ausgabe läuft nicht")) }
            guard let r = masterRing ?? RecordRing(capacityFrames: RecordRing.standardFrames) else { throw Failure(errorDescription: "RAM") }
            masterRing = r
            ring = r; rate = mix.engine.sampleRate; act = .master(pair: testSource != nil ? 0 : mix.internalPair)
        } else {
            let info = try startInput(mix)
            guard let r = inputRing else { throw Failure(errorDescription: "RAM") }
            ring = r; rate = info.rate; act = .input(name: info.name, pair: info.firstChannel, rate: info.rate)
            if let out = mix.engine.routing.device, out != info.device, abs(info.rate - mix.engine.outputRate) > 0.5 {
                StatusCenter.post(.info, String(format: String(localized: "Eingang %@ kHz, Ausgang %@ kHz: Datei mit der Rate des Eingangs"),
                                                khz(info.rate), khz(mix.engine.outputRate)), key: "record.rate")
            }
        }
        let folder = folderOverride ?? prefs.folderURL
        let file = folder.appendingPathComponent(stem + "." + prefs.format.ext)
        let s: RecordSink
        do { s = try RecordSink(ring: ring, url: file, kind: prefs.format, sampleRate: rate) } catch {
            if src == .input, !monitoring { input.stop() }
            throw error
        }
        s.onError = { [weak self] why in
            Task { @MainActor in self?.writeFailed(why) }
        }
        if case let .master(pair) = act { mix.engine.setMasterTap(ring, firstChannel: pair) }
        s.start()
        sink = s
        url = file
        active = act
        startedAt = now
        dropouts = 0
        recording = true
        playingAtStart = Set((0..<MixEngine.deckCount).compactMap { d in mix.deck(d).playing ? mix.deck(d).track?.key : nil })
        startMeter()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.writeTracklist(end: nil) } }
        RunLoop.main.add(t, forMode: .common)
        listTimer = t
        print("[record] Start: \(file.path) · \(act.label) · \(Int(rate)) Hz")
        StatusCenter.post(.info, String(localized: "Aufnahme läuft: \(file.lastPathComponent)"), detail: act.label, key: "record")
    }

    /// Eingang starten (Aufnahme oder Pegel). Läuft er schon auf demselben Gerät und Paar, bleibt er
    @discardableResult
    private func startInput(_ mix: MixModel) throws -> CoreAudioInput.Info {
        let dev = inputDevice(mix)
        let first = mix.prefs.record.inputFirstChannel
        if let i = input.info, input.running, i.device == dev, i.firstChannel == first { return i }
        guard let ring = inputRing ?? RecordRing(capacityFrames: RecordRing.standardFrames) else { throw Failure(errorDescription: "RAM") }
        inputRing = ring
        guard let dev else { throw CoreAudioInput.InputError.noDevice }
        return try input.start(device: dev, firstChannel: first, ring: ring)
    }

    /// Aufnahme beenden: Datei schließen, Tracklist schreiben, Statuszeile
    func stop(note: String? = nil) {
        guard recording, let s = sink, !stopping else { return }
        stopping = true
        let end = Date()
        let act = active
        s.stop { [weak self] stats in
            Task { @MainActor in self?.finished(stats, end: end, active: act, note: note) }
        }
    }

    /// Beenden der App: sofort und blockierend schließen
    func stopNow() {
        guard recording, let s = sink else { return }
        let stats = s.stopNow()
        finished(stats, end: Date(), active: active, note: nil)
    }

    private func finished(_ stats: RecordSink.Stats, end: Date, active act: Active?, note: String?) {
        if case .master = act { mix?.engine.setMasterTap(nil, firstChannel: -1) }
        writeTracklist(end: end)
        listTimer?.invalidate(); listTimer = nil
        let secs = Double(stats.frames) / max(1, sink?.sampleRate ?? 1)
        let name = url?.lastPathComponent ?? "?"
        print(String(format: "[record] Stopp: %@ · %d Frames (%.2f s) · %d Aussetzer (%d Frames)", name, stats.frames, secs,
                     stats.overflows, stats.droppedFrames))
        var text = String(localized: "Aufnahme gespeichert: \(name) · \(Self.clock(secs))")
        if stats.overflows > 0 { text += " · " + String(localized: "Aufnahme: \(stats.overflows) Aussetzer") }
        if let note { text = note + " – " + text }
        StatusCenter.post(stats.overflows > 0 || note != nil ? .warning : .ok, text, detail: url?.deletingLastPathComponent().path, key: "record")
        lastStats = stats
        sink = nil
        recording = false
        stopping = false
        startedAt = nil
        active = nil
        if case .input = act, !wantsMonitor { input.stop() }
        updateMonitoring()
    }

    /// letzte abgeschlossene Aufnahme (Selbsttest)
    @ObservationIgnored private(set) var lastStats: RecordSink.Stats?

    private func writeFailed(_ why: String) {
        guard recording else { return }
        stop(note: String(localized: "Aufnahme: Schreibfehler (\(why))"))
    }

    private func fail(_ s: String) {
        print("[record] \(s)")
        StatusCenter.post(.error, s, key: "record")
    }

    // MARK: Gerät

    /// Ausgabe weg / Ruhezustand: Aufnahme sauber schließen (nicht automatisch fortsetzen)
    func outputLost(_ name: String) {
        guard recording else { return }
        if case .input = active, let i = input.info, i.device != mix?.engine.routing.device { return }   // Eingang auf anderem Gerät läuft weiter
        stop(note: String(localized: "\(name) weg"))
    }

    private func inputEvent(_ e: CoreAudioInput.Event) {
        guard let i = input.info else { return }
        switch e {
        case .alive(false):
            if recording, case .input = active { stop(note: String(localized: "\(i.name) weg")) }
            input.stop()
            monitoring = false
        case let .rate(r) where abs(r - i.rate) > 0.5:
            if recording, case .input = active {
                stop(note: String(format: String(localized: "Eingangsrate %@ → %@ kHz"), khz(i.rate), khz(r)))
            } else {
                input.stop(); monitoring = false; updateMonitoring()
            }
        default: break
        }
    }

    /// Routing geändert: Master-Abgriff folgt dem Main-Paar; danach Eingangspegel nach Einstellung
    func routingChanged() {
        if recording, case .master = active, testSource == nil, let mix, let r = masterRing {
            mix.engine.setMasterTap(r, firstChannel: mix.internalPair)
            active = .master(pair: mix.internalPair)
        }
        updateMonitoring()
    }

    // MARK: Pegel ohne Aufnahme

    /// Selbsttest / Bilder: nie ein Eingang nur für die Anzeige (könnte das Live-Interface sein)
    private var wantsMonitor: Bool {
        guard let mix, !Session.isSelfTest else { return false }
        return mix.prefs.record.showInputLevel && source(mix) == .input
    }

    /// Eingangspegel an/aus nach Einstellung, Quelle und Modus (nicht während einer Aufnahme)
    func updateMonitoring() {
        guard let mix, !recording, !stopping else { return }
        if wantsMonitor {
            let dev = inputDevice(mix), first = mix.prefs.record.inputFirstChannel
            if monitoring, input.running, input.info?.device == dev, input.info?.firstChannel == first { return }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { @MainActor in self?.updateMonitoring() } }
                return
            default:
                StatusCenter.post(.warning, String(localized: "Kein Zugriff auf Audio-Eingänge (Systemeinstellungen → Datenschutz → Mikrofon)"), key: "record.input")
                return
            }
            do {
                try startInput(mix)
                monitoring = true
                startMeter()
            } catch {
                monitoring = false
                StatusCenter.post(.warning, String(localized: "Eingangspegel: \(error.localizedDescription)"), key: "record.input")
            }
        } else if monitoring {
            input.stop()
            monitoring = false
            stopMeter()
        }
    }

    /// Ring, dessen Pegel die Anzeigen zeigen
    private var meterRing: RecordRing? {
        if recording, case .master = active { return masterRing }
        return input.running ? inputRing : nil
    }

    var meterActive: Bool { recording || monitoring }

    private func startMeter() {
        guard meterTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.stepMeter() } }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func stopMeter() {
        meterTimer?.invalidate(); meterTimer = nil
        level = Level()
    }

    private func stepMeter() {
        guard meterActive, let ring = meterRing else { if !meterActive { stopMeter() }; return }
        let p = ring.takePeak(), now = Date()
        var l = level
        l.l = max(p.left, l.l * 0.8); l.r = max(p.right, l.r * 0.8)
        if p.left >= l.holdL || now.timeIntervalSince(holdAt.0) > 1.5 { l.holdL = p.left; holdAt.0 = now }
        if p.right >= l.holdR || now.timeIntervalSince(holdAt.1) > 1.5 { l.holdR = p.right; holdAt.1 = now }
        if max(p.left, p.right) >= 0.999 { l.clip = now }
        level = l
        if recording, let s = sink {
            let o = s.stats.overflows
            if o != dropouts {
                dropouts = o
                StatusCenter.post(.warning, String(localized: "Aufnahme: \(o) Aussetzer"), key: "record.drop")
            }
        }
    }

    // MARK: Tracklist

    private func writeTracklist(end: Date?) {
        guard let url, let start = startedAt else { return }
        let played = (history?.live ?? []).map { SetTracklist.Played(start: $0.start, key: $0.key, artist: $0.artist, title: $0.title) }
        let list = SetTracklist(history: played, start: start, end: end, playingAtStart: playingAtStart)
        let stem = url.deletingPathExtension()
        let cue = list.cue(audioFile: url.lastPathComponent, title: stem.lastPathComponent, date: start)
        let text = list.text
        DispatchQueue.global(qos: .utility).async {
            try? text.write(to: stem.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            try? cue.write(to: stem.appendingPathExtension("cue"), atomically: true, encoding: .utf8)
        }
        lastTracklist = list
    }

    /// zuletzt geschriebene Tracklist (Selbsttest)
    @ObservationIgnored private(set) var lastTracklist: SetTracklist?

    // MARK: Anzeige

    /// Laufzeit der Aufnahme in Sekunden
    func elapsed(_ now: Date = Date()) -> Double { startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0 }

    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Callback-Kosten des Eingangs (Selbsttest, Statistik)
    func takeInputStats() -> (blocks: Int, averageMs: Double, worstMs: Double, errors: Int) { input.takeStats() }
}

private func khz(_ r: Double) -> String { String(format: "%g", r / 1000) }

// MARK: - Anzeigen

/// ● REC: Klick = Start / Stopp. Rot nur der Punkt (blinkt langsam während der Aufnahme), Laufzeit, Pegel L/R
struct RecordButton: View {
    @Environment(MixModel.self) private var mix
    /// kompakt: eine Zeile (Mixer), sonst zwei Zeilen (obere Leiste)
    var compact = false

    var body: some View {
        let rec = mix.recorder
        Button { rec.toggle() } label: {
            Group {
                if compact {
                    HStack(spacing: 4.z) { dot(rec); label(rec) }
                        .frame(height: 18.z)
                } else {
                    VStack(spacing: 1.z) {
                        HStack(spacing: 4.z) { dot(rec); Text(verbatim: "REC").font(Theme.label(10.z, .heavy)) }
                        label(rec)
                    }
                    .frame(height: 30.z)
                }
            }
            .padding(.horizontal, 4.z)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(UITestMark(name: compact ? "rec mixer" : "rec"))
        .help(rec.recording ? Text("Aufnahme stoppen") : Text("Aufnahme starten · Quelle ⌘, → AUDIO → Aufnahme"))
    }

    private var sourceLabel: String {
        guard mix.recorder.source(mix) == .input else { return "MASTER" }
        let p = mix.prefs.record.inputFirstChannel
        return "IN \(p + 1)/\(p + 2)"
    }

    @ViewBuilder private func dot(_ rec: SetRecorder) -> some View {
        if rec.recording {
            TimelineView(.periodic(from: .now, by: 0.5)) { t in
                let on = Int(t.date.timeIntervalSinceReferenceDate) % 2 == 0
                Text(verbatim: "●").font(Theme.mono(11.z)).foregroundStyle(Theme.state.opacity(on ? 1 : 0.25))
            }
        } else {
            Text(verbatim: "●").font(Theme.mono(11.z)).foregroundStyle(rec.monitoring ? Theme.bone : Theme.muted)
        }
    }

    @ViewBuilder private func label(_ rec: SetRecorder) -> some View {
        if rec.recording {
            TimelineView(.periodic(from: .now, by: 0.5)) { t in
                Text(verbatim: SetRecorder.clock(rec.elapsed(t.date))).font(Theme.mono(compact ? 10.z : 12.z, .semibold)).foregroundStyle(Theme.bone)
            }
        } else if compact {
            Text(verbatim: "REC").font(Theme.label(9.z, .heavy)).foregroundStyle(Theme.muted)
        } else {
            // Quelle der nächsten Aufnahme
            Text(verbatim: sourceLabel).font(Theme.label(9.z, .bold)).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
}

/// Pegel der Aufnahme / des Eingangs: zwei Balken L/R mit gehaltener Spitze, rot bei Clipping (letzte 2 s)
struct RecordMeter: View {
    @Environment(MixModel.self) private var mix
    var width: CGFloat = 56

    var body: some View {
        let rec = mix.recorder
        LiveCanvas(fps: 20, running: rec.meterActive) { [rec] ctx, size in
            let l = rec.level
            let clip = l.clip.map { Date().timeIntervalSince($0) < 2 } ?? false
            ctx.setFillColor(CG.void); ctx.fill(CGRect(origin: .zero, size: size))
            let h = max(1, (size.height - 1) / 2)
            for (i, (v, hold)) in [(l.l, l.holdL), (l.r, l.holdR)].enumerated() {
                let y = CGFloat(i) * (h + 1)
                ctx.setFillColor(CG.hairline); ctx.fill(CGRect(x: 0, y: y, width: size.width, height: h))
                ctx.setFillColor(clip ? CG.state : CG.bone)
                ctx.fill(CGRect(x: 0, y: y, width: size.width * CGFloat(Self.scale(v)), height: h))
                if hold > 0 {
                    ctx.setFillColor(hold >= 0.999 ? CG.state : CG.bone)
                    ctx.fill(CGRect(x: min(size.width - 1.5, size.width * CGFloat(Self.scale(hold))), y: y, width: 1.5, height: h))
                }
            }
        }
        .frame(width: width.z, height: 5.z)
        .help("Pegel der Aufnahme (Spitze, gehalten), rot = Clipping")
    }

    /// −48 … 0 dBFS linear auf die Breite
    static func scale(_ v: Float) -> Float {
        guard v > 0 else { return 0 }
        return max(0, min(1, (20 * log10(v) + 48) / 48))
    }
}

/// obere Leiste: REC neben Uhr / Stoppuhr
struct RecordPanel: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        VStack(spacing: 2.z) {
            RecordButton()
            RecordMeter(width: 52)
        }
        .frame(width: 64.z).frame(minHeight: 42.z, maxHeight: .infinity)
        .overlay(Rectangle().stroke(mix.recorder.recording ? Theme.bone : Theme.hairline, lineWidth: 1))
    }
}
