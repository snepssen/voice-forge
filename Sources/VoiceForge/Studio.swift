import AVFoundation
import Foundation
import SwiftUI
import VoiceForgeCore
import VoiceForgeTTS

/// Everything the window is looking at.
@MainActor
final class Studio: ObservableObject {

    @Published var text: String = """
    Welcome back to the channel. Today we are looking at something a little different.

    I have been building a text to speech tool, and the interesting part is not the voice — it is the timing. A comma is worth about half a second here, which is longer than most people expect.
    """
    @Published var voice: String = VoiceEngine.bundledVoices().first ?? ""
    @Published var settings = SynthesisSettings()
    @Published var export = Export.Settings()

    @Published private(set) var rendered: [RenderedSentence] = []
    @Published private(set) var calibration: PauseCalibration?
    @Published private(set) var busy: String?
    @Published private(set) var progress: Double = 0
    @Published var error: String?
    @Published var lastReceipt: Export.Receipt?
    /// What exporting would do, computed after every render and whenever the
    /// export settings change. Measured at the *export* rate, because loudness
    /// and true peak both move with resampling.
    @Published private(set) var exportPreview: Export.Preview?
    @Published var selected: Int?

    /// Rebuilt from `text` on every keystroke. Cheap — no model involved.
    var script: Script { Script.parse(text) }

    var voices: [String] { VoiceEngine.bundledVoices() }

    /// Where the session is kept between launches.
    ///
    /// The calibration is the reason this exists. It costs about thirty seconds
    /// of rendering to produce and it does not change unless the voice or the
    /// pace does — losing it on quit meant paying for it again every launch, to
    /// learn the same numbers. The script and the dials come along because
    /// re-typing a script to hear one word differently is the same waste in a
    /// smaller denomination.
    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appending(path: "Voice Forge")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "session.json")
    }

    private struct Saved: Codable {
        var text: String
        var voice: String
        var settings: SynthesisSettings
        var export: Export.Settings
        /// Kept per voice, because a calibration does not transfer between them.
        var calibrations: [String: PauseCalibration]
    }

    private var calibrations: [String: PauseCalibration] = [:]
    private var loading = false

    func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Self.stateURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        text = saved.text
        // Only if it is still bundled -- a saved voice that has since been
        // removed must not leave the picker pointing at nothing.
        if voices.contains(saved.voice) { voice = saved.voice }
        settings = saved.settings
        export = saved.export
        calibrations = saved.calibrations
        calibration = calibrations[voice]
    }

    func save() {
        guard !loading else { return }
        let saved = Saved(text: text, voice: voice, settings: settings,
                          export: export, calibrations: calibrations)
        try? JSONEncoder().encode(saved).write(to: Self.stateURL, options: .atomic)
    }

    /// Switching voice swaps in that voice's own calibration, or none.
    func voiceChanged() {
        calibration = calibrations[voice]
        save()
    }

    private var engines: [String: VoiceEngine] = [:]
    private var player: AVAudioPlayer?
    private var previewURL: URL?

    /// Loading a model takes a moment, so each one is kept once it is built.
    /// Both fit in memory comfortably at ~63 MB each, and the whole point of
    /// this app is switching between them.
    private func engine(_ name: String) throws -> VoiceEngine {
        if let e = engines[name] { return e }
        let e = try VoiceEngine(voice: name)
        engines[name] = e
        return e
    }

    var sampleRate: Double { (try? engine(voice))?.sampleRate ?? Audio.modelSampleRate }

    // MARK: totals

    var totalSeconds: Double {
        rendered.reduce(0) { $0 + $1.seconds + $1.trailingGap }
    }
    var spokenSeconds: Double { rendered.reduce(0) { $0 + $1.seconds } }
    var silentSeconds: Double { totalSeconds - spokenSeconds }
    var wordsPerMinute: Double {
        totalSeconds > 0 ? Double(script.wordCount) / totalSeconds * 60 : 0
    }

    /// What the finished take measures, before any export gain.
    var takeLUFS: Double {
        guard !rendered.isEmpty else { return -.infinity }
        return Loudness.integratedLUFS(assembled(), rate: sampleRate)
    }

    func assembled() -> [Float] {
        guard let e = try? engine(voice) else { return [] }
        return e.assemble(rendered)
    }

    // MARK: work

    func renderAll() async {
        guard !script.isEmpty else { rendered = []; return }
        busy = "Rendering"; progress = 0; error = nil
        let s = settings, v = voice, sc = script
        do {
            let e = try engine(v)
            let out = try await Task.detached { [weak self] in
                try e.render(sc, settings: s) { i, n in
                    Task { @MainActor in self?.progress = Double(i) / Double(n) }
                }
            }.value
            rendered = out
        } catch { self.error = error.localizedDescription }
        busy = nil; progress = 0
        refreshPreview()
    }

    /// Recompute the export preview. Cheap relative to rendering, but it does
    /// resample the whole take, so it is called on change rather than from a
    /// view body.
    func refreshPreview() {
        let audio = assembled()
        guard !audio.isEmpty else { exportPreview = nil; return }
        let rate = sampleRate, settings = export
        Task.detached { [weak self] in
            let p = Export.preview(audio, at: rate, settings: settings)
            await MainActor.run { self?.exportPreview = p }
        }
    }

    /// Re-render one sentence. The model is stochastic, so this is a genuinely
    /// different take of the same words rather than a no-op — which is the
    /// point: one line in ten lands oddly and re-rolling it is cheaper than
    /// rewriting it.
    func reroll(_ id: Int) async {
        guard let index = rendered.firstIndex(where: { $0.id == id }) else { return }
        busy = "Re-rolling"; error = nil
        do {
            let e = try engine(voice)
            let old = rendered[index]
            let samples = try e.renderSentence(old.text, settings: settings)
            let seconds = Audio.seconds(samples, at: e.sampleRate)
            let words = old.text.split(whereSeparator: \.isWhitespace).count
            defer { refreshPreview() }
            rendered[index] = RenderedSentence(
                id: old.id, text: old.text, samples: samples,
                trailingGap: old.trailingGap, seconds: seconds,
                peakDBFS: Audio.peakDBFS(samples),
                wordsPerMinute: seconds > 0 ? Double(words) / seconds * 60 : 0)
        } catch { self.error = error.localizedDescription }
        busy = nil
    }

    func calibrate() async {
        busy = "Measuring"; progress = 0; error = nil
        let s = settings, v = voice
        do {
            let e = try engine(v)
            let cal = try await Task.detached { [weak self] in
                try e.calibratePauses(settings: s) { i, n in
                    Task { @MainActor in self?.progress = Double(i) / Double(n) }
                }
            }.value
            calibration = cal
            calibrations[v] = cal
            save()
        } catch { self.error = error.localizedDescription }
        busy = nil; progress = 0
    }

    /// Whether the calibration on screen still describes what is set.
    var calibrationIsStale: Bool {
        guard let calibration else { return false }
        return !calibration.describes(settings, voice: voice)
    }

    // MARK: listening

    func play() {
        let audio = assembled()
        guard !audio.isEmpty else { return }
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "voice-forge-preview.wav")
            try Export.writeWAV(audio, rate: sampleRate, depth: .pcm16, to: url)
            previewURL = url
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch { self.error = error.localizedDescription }
    }

    func playOne(_ id: Int) {
        guard let r = rendered.first(where: { $0.id == id }), !r.samples.isEmpty else { return }
        do {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "voice-forge-sentence.wav")
            try Export.writeWAV(r.samples, rate: sampleRate, depth: .pcm16, to: url)
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch { self.error = error.localizedDescription }
    }

    func stop() { player?.stop(); player = nil }

    // MARK: export

    func exportTake(to url: URL) {
        let audio = assembled()
        guard !audio.isEmpty else { error = "Nothing rendered yet."; return }
        do { lastReceipt = try Export.write(audio, at: sampleRate, to: url, settings: export) }
        catch { self.error = error.localizedDescription }
    }
}
