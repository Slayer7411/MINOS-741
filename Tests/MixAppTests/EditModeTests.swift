import AVFoundation
import Foundation
import Testing
import MixCore
import MixMedia
@testable import MixEngine
@testable import MixApp

// EDIT-Modus: gerenderte Schnittliste ins Deck tauschen (ohne Laden) und zurück; Tastenkürzel ohne Standardbelegung.

private func toneWAV(seconds: Double) throws -> URL {
    let rate = 44100.0
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-edit-\(UUID().uuidString).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(seconds * rate))!
    buf.frameLength = buf.frameCapacity
    for c in 0..<2 { for i in 0..<Int(buf.frameLength) { buf.floatChannelData![c][i] = Float(sin(Double(i) * 0.03)) * 0.5 } }
    try file.write(from: buf)
    return url
}

@MainActor
struct EditModeTests {
    @Test func swapRenderedListAndBack() async throws {
        let core = MixController()
        let url = try toneWAV(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        var t = Track(key: url.path, path: url.path)
        t.bpm = 120
        t.cues = [Cue(name: "Grid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1),
                  Cue(name: "h", kind: .cue, startMs: 12_000, lengthMs: 0, hotcue: 0)]
        core.load(t, deck: 0)
        let loadDeadline = Date().addingTimeInterval(60)
        while (core.trackAudio(0) == nil), Date() < loadDeadline { try await Task.sleep(for: .milliseconds(20)) }
        let src = try #require(core.trackAudio(0))
        // 4 s entfernen (2 Takte), Liste rendern wie der EDIT-Modus
        var e = EditList(duration: src.duration)
        e.remove(TrackRange(4, 8))
        let f = e.frames(rate: src.sampleRate, sourceFrames: src.frames)
        let splice = AudioSplice(pieces: f.pieces, sourceFrames: src.frames, fade: AudioSplice.fadeFrames(sampleRate: src.sampleRate), muted: f.muted)
        let a = TrackAudio.rendered(splice, from: src)
        #expect(a.frames == src.frames - Int((4 * src.sampleRate).rounded()))
        var p = TrackCut.track(from: t, key: t.key, path: t.path, grid: BeatGrid(track: t), hotcues: t.hotcues, edl: e, duration: a.duration)
        p.title = "x [edit]"
        #expect(core.swapAudio(0, track: p, audio: a, position: 9, cuePoint: 0))
        let s = core.snapshot().decks[0]
        #expect(core.trackAudio(0) === a && abs(s.duration - 16) < 0.01 && s.track?.title == "x [edit]")
        #expect(s.hotcues[0].map { abs($0.startMs - 8000) < 0.5 } == true)   // Hotcue 12 s -> 8 s
        #expect(s.grid?.bpm == 120 && s.loading == false)
        // zurück zum Original
        #expect(core.swapAudio(0, track: t, audio: src, position: 13, cuePoint: 0))
        #expect(core.trackAudio(0) === src && abs(core.snapshot().decks[0].duration - 20) < 0.01)
    }

    @Test func editShortcutsHaveNoDefault() {
        for a in [ShortcutID.editRemove, .editKeep, .editDuplicate, .editMute, .editLeft, .editRight, .editMark, .editSnap, .editRender,
                  .toolLoop2, .toolLoop4, .toolLoop8, .toolLoop16] {
            #expect(a.defaultCombo == nil)
            #expect(a.group == .decks)
            #expect(!a.title.isEmpty)
        }
        #expect(ShortcutID.toolLoop16.index == 16)
    }
}

/// Übersichtsbild: Pixelhöhe aus der Einstellung (Stufen von 60 px), nicht hochskaliert
@MainActor @Test func overviewBitmapHeightFollowsSetting() async throws {
    #expect(RenderedWaveform.overviewPixels(points: 18, zoom: 1) == 60)
    #expect(RenderedWaveform.overviewPixels(points: 30, zoom: 1) == 60)
    #expect(RenderedWaveform.overviewPixels(points: 31, zoom: 1) == 120)
    #expect(RenderedWaveform.overviewPixels(points: 90, zoom: 1) == 180)
    #expect(RenderedWaveform.overviewPixels(points: 120, zoom: 1.5) == 360)
    #expect(RenderedWaveform.overviewPixels(points: 120, zoom: 3) == 480)
    let url = try toneWAV(seconds: 4)
    defer { try? FileManager.default.removeItem(at: url) }
    let a = try TrackAudio.decode(url: url, sampleRate: 44100)
    for style in [WaveformStyle.blend, .mono] {
        let w = RenderedWaveform.render(a, style: style, palette: .rgb, overviewHeight: 180)
        #expect(w.overview?.height == 180 && w.overview?.width == 1600, "\(style)")
        #expect(RenderedWaveform.render(a, style: style, palette: .rgb).overview?.height == 60, "\(style)")
    }
    // Cache-Schlüssel enthält die Höhe: andere Höhe -> neues Bild
    let cache = WaveformCache()
    var ui = UIPrefs()
    ui.waveformStyle = .blend
    ui.overviewHeight = 90
    for _ in 0..<500 where cache.waveform(for: a, ui: ui, preset: WavePresets.standard)?.overview?.height != 180 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(cache.waveform(for: a, ui: ui, preset: WavePresets.standard)?.overview?.height == 180)
}
