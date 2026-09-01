import AVFoundation
import Foundation
import OnnxRuntimeBindings
import VoiceForgeCore

/// The bundled voice's config.json — the exact fields `piper.voice.PiperVoice`
/// reads, decoded the same way.
struct PiperVoiceConfig: Decodable {
    struct Audio: Decodable { var sample_rate: Int }
    struct Espeak: Decodable { var voice: String }
    struct Inference: Decodable {
        var noise_scale: Double
        var length_scale: Double
        var noise_w: Double
    }
    var audio: Audio
    var espeak: Espeak
    var inference: Inference
    var phoneme_id_map: [String: [Int]]
}

public enum VoiceEngineError: LocalizedError {
    case noEnvironment
    case noModel(String)
    case noOutput
    case resampler(String)

    public var errorDescription: String? {
        switch self {
        case .noEnvironment: "The ONNX runtime failed to start."
        case .noModel(let v): "No bundled model for the voice \"\(v)\"."
        case .noOutput: "The model produced no output."
        case .resampler(let why): "Resampling failed: \(why)."
        }
    }
}

/// One rendered sentence, with everything measured about it.
///
/// The app shows these per sentence rather than only as a finished take,
/// because the whole point of this tool is being able to see which line is the
/// one running long or landing quiet.
public struct RenderedSentence: Sendable {
    public var id: Int
    public var text: String
    public var samples: [Float]
    /// Silence laid *after* this sentence before the next one begins.
    public var trailingGap: Double
    public var seconds: Double
    public var peakDBFS: Double
    /// Words per minute over this sentence alone, silence included.
    public var wordsPerMinute: Double
}

/// The synthesiser, with its dials on the outside.
///
/// The engine itself is Gateway Forge's, copied rather than shared, and the
/// two decisions it arrived at by measurement are kept as defaults rather than
/// as constants: one inference call per sentence, and two trailing padding
/// phonemes with the final full stop dropped. What is different here is that
/// they are `SynthesisSettings` fields — a voiceover has reasons a meditation
/// tape does not, and this tool exists to let someone find out what they cost.
public final class VoiceEngine: @unchecked Sendable {
    private let session: ORTSession
    private let phonemizer: EspeakPhonemizer
    private let config: PiperVoiceConfig
    public let voice: String

    private nonisolated(unsafe) static let env: ORTEnv? = try? ORTEnv(loggingLevel: .warning)

    /// The rate this model actually speaks at, read from its own config.
    public var sampleRate: Double { Double(config.audio.sample_rate) }

    /// Which voices are bundled, by name. Derived from the resources actually
    /// present rather than from a list — the same rule the packaging gate uses,
    /// after a hardcoded filename let a deleted model keep shipping.
    public static func bundledVoices() -> [String] {
        guard let dir = Bundle.module.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard name.hasPrefix("en_US-"), name.hasSuffix("-medium.onnx") else { return nil }
            return String(name.dropFirst("en_US-".count).dropLast("-medium.onnx".count))
        }.sorted()
    }

    public init(voice: String) throws {
        guard let env = Self.env else { throw VoiceEngineError.noEnvironment }
        self.voice = voice
        let stem = "en_US-\(voice)-medium"
        guard let modelURL = Bundle.module.url(forResource: stem, withExtension: "onnx"),
              let configURL = Bundle.module.url(forResource: stem + ".onnx", withExtension: "json"),
              let dataDir = Bundle.module.url(forResource: "espeak-ng-data", withExtension: nil)
        else { throw VoiceEngineError.noModel(voice) }
        config = try JSONDecoder().decode(PiperVoiceConfig.self, from: Data(contentsOf: configURL))
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: nil)
        phonemizer = try EspeakPhonemizer(dataDirectory: dataDir, voice: config.espeak.voice)
    }

    // MARK: rendering

    /// Render a whole script, sentence by sentence, laying the requested
    /// silence between them.
    public func render(_ script: Script, settings: SynthesisSettings,
                       onSentence: ((Int, Int) -> Void)? = nil) throws -> [RenderedSentence] {
        var out: [RenderedSentence] = []
        for (i, sentence) in script.sentences.enumerated() {
            onSentence?(i, script.sentences.count)
            let samples = try renderSentence(sentence.text, settings: settings)
            // The gap that follows this sentence. A paragraph break replaces
            // the sentence gap rather than adding to it -- two silences laid
            // end to end is how a "0.6 s paragraph" quietly becomes 0.68.
            let gap: Double = i == script.sentences.count - 1
                ? 0
                : (sentence.endsParagraph ? settings.paragraphGap : settings.sentenceGap)
            let seconds = Audio.seconds(samples, at: sampleRate)
            let words = sentence.text.split(whereSeparator: \.isWhitespace).count
            out.append(RenderedSentence(
                id: sentence.id, text: sentence.text, samples: samples,
                trailingGap: gap, seconds: seconds,
                peakDBFS: Audio.peakDBFS(samples),
                wordsPerMinute: seconds > 0 ? Double(words) / seconds * 60 : 0))
        }
        return out
    }

    /// Lay rendered sentences into one buffer with their gaps between them.
    public func assemble(_ rendered: [RenderedSentence]) -> [Float] {
        var out: [Float] = []
        for r in rendered {
            out += r.samples
            out += Audio.silence(seconds: r.trailingGap, at: sampleRate)
        }
        return out
    }

    /// One sentence, one inference call. Never less, never more.
    public func renderSentence(_ text: String, settings: SynthesisSettings) throws -> [Float] {
        let phonemized = try phonemizer.phonemize(text, dropFinalStop: settings.dropFinalFullStop)
        let ids = phonemeIDs(phonemized, settings: settings)
        guard !ids.isEmpty else { return [] }
        return try infer(ids: ids, settings: settings)
    }

    /// Phonemes to model ids: BOS, PAD after every phoneme, EOS.
    ///
    /// Iterates by Unicode *scalar*, matching Python's `list(str)` — Swift's
    /// default `Character` iteration would group a base letter with a
    /// following combining diacritic into one grapheme cluster and silently
    /// fail to match either half's separate entry.
    ///
    /// The one addition this app makes is `clausePads`: extra PAD ids after a
    /// clause mark. PAD is a phoneme the model saw everywhere in training, so
    /// spending more of them at a breath is in-distribution — unlike cutting
    /// the sentence at the comma and splicing silence, which puts a cold start
    /// where a breath belongs and was heard as a stutter.
    func phonemeIDs(_ phonemized: String, settings: SynthesisSettings) -> [Int] {
        let map = config.phoneme_id_map
        let pad = map["_"] ?? []
        var ids: [Int] = []
        ids += map["^"] ?? []
        ids += pad
        for scalar in phonemized.unicodeScalars {
            let key = String(scalar)
            guard let id = map[key] else { continue }
            ids += id
            ids += pad
            if settings.clausePads > 0,
               let ch = key.first, Script.clauseMarks.contains(ch) {
                for _ in 0 ..< settings.clausePads { ids += pad }
            }
        }
        for _ in 0 ..< settings.trailingPads { ids += pad }
        ids += map["$"] ?? []
        return ids
    }

    private func infer(ids: [Int], settings: SynthesisSettings) throws -> [Float] {
        let inputData = NSMutableData(bytes: ids.map { Int64($0) }, length: ids.count * 8)
        let inputTensor = try ORTValue(tensorData: inputData, elementType: .int64,
                                       shape: [1, NSNumber(value: ids.count)])
        var lengthValue = Int64(ids.count)
        let lengthData = NSMutableData(bytes: &lengthValue, length: 8)
        let lengthTensor = try ORTValue(tensorData: lengthData, elementType: .int64, shape: [1])

        // The order is the model's, not ours: noise, length, noise_w.
        var scales: [Float] = [Float(settings.noiseScale),
                               Float(settings.lengthScale),
                               Float(settings.noiseW)]
        let scalesData = NSMutableData(bytes: &scales, length: 12)
        let scalesTensor = try ORTValue(tensorData: scalesData, elementType: .float, shape: [3])

        let outputs = try session.run(
            withInputs: ["input": inputTensor, "input_lengths": lengthTensor, "scales": scalesTensor],
            outputNames: ["output"], runOptions: nil)
        guard let tensor = outputs["output"], let data = try tensor.tensorData() as Data?
        else { throw VoiceEngineError.noOutput }

        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    // MARK: measurement

    /// Measure what each punctuation mark is actually worth, for this voice at
    /// these settings.
    ///
    /// **By total duration, not by looking for the gap.** The obvious method —
    /// render a line, find the silence in the middle, call that the comma — was
    /// tried first and does not work. Two reasons, both instructive:
    ///
    /// - *The model has no silence to find.* Its pauses sit at an amplitude
    ///   around 0.005–0.01, which is breath rather than digital zero. A trim
    ///   threshold of 0.002 reported an 11 ms comma; 0.01 reported 434 ms on
    ///   the same line. The answer was entirely an artifact of the threshold.
    /// - *The model is stochastic.* `noise_w` varies phoneme durations between
    ///   draws by design, so the same sentence rendered twice has a different
    ///   rhythm. Successive draws at 0, 4, 8 and 12 clause pads gave longest
    ///   gaps of 434, 213, 300 and 265 ms — no signal at all — while the total
    ///   durations went 3.29, 3.27, 3.48, 3.69 s, which is the trend actually
    ///   there.
    ///
    /// So: render the same words with and without the mark and subtract the
    /// durations. Nothing has to be located, no threshold is involved, and the
    /// words either side are identical by construction.
    ///
    /// Measurement runs with `noiseW` forced to zero — the duration predictor
    /// stops sampling and becomes repeatable, which is the whole point when
    /// what is being measured *is* a duration. The result therefore describes
    /// the model's central tendency rather than any one take, which is the
    /// right thing for a dial to be calibrated against.
    public func calibratePauses(settings: SynthesisSettings,
                                marks: [String] = [",", ";", ":", "—"],
                                onProgress: ((Int, Int) -> Void)? = nil) throws -> PauseCalibration {
        var deterministic = settings
        deterministic.noiseW = 0
        deterministic.clausePads = 0

        var results: [PauseCalibration.Mark] = []
        var step = 0
        let probeCount = PauseCalibration.probes(for: ",").count
        let total = marks.count * probeCount * 2 + 4

        func duration(_ text: String, _ s: SynthesisSettings) throws -> Double {
            step += 1; onProgress?(step, total)
            return Audio.seconds(try renderSentence(text, settings: s), at: sampleRate)
        }

        for mark in marks {
            var deltas: [Double] = []
            for probe in PauseCalibration.probes(for: mark) {
                let a = try duration(probe.with, deterministic)
                let b = try duration(probe.without, deterministic)
                deltas.append(Swift.max(0, a - b))
            }
            guard !deltas.isEmpty else { continue }
            results.append(.init(mark: mark,
                                 mean: deltas.reduce(0, +) / Double(deltas.count),
                                 minimum: deltas.min() ?? 0, maximum: deltas.max() ?? 0,
                                 samples: deltas.count))
        }

        // What one clause pad buys, from the slope across the whole range
        // rather than from one endpoint pair -- a single difference would ride
        // on whatever the duration predictor happened to do at that one count.
        var perPadSamples: [Double] = []
        let padProbe = PauseCalibration.probes(for: ",")[0].with
        let base = try duration(padProbe, deterministic)
        for pads in [4, 8, 12] {
            var padded = deterministic; padded.clausePads = pads
            let d = try duration(padProbe, padded)
            perPadSamples.append((d - base) / Double(pads))
        }
        let perPad = Swift.max(0, perPadSamples.reduce(0, +) / Double(perPadSamples.count))

        return PauseCalibration(voice: voice, lengthScale: settings.lengthScale,
                                marks: results, secondsPerClausePad: perPad)
    }

    /// The longest silence inside a rendered line, ignoring its head and tail.
    ///
    /// Head and tail are excluded deliberately: an utterance begins and ends
    /// quiet, and those runs are usually longer than any pause inside it, so
    /// including them would measure the model's onset rather than its comma.
    private func gapSeconds(_ samples: [Float]) -> Double {
        let head = Audio.quietHead(samples)
        let tail = Audio.quietTail(samples)
        guard samples.count > head + tail else { return 0 }
        let interior = Array(samples[head ..< (samples.count - tail)])
        guard let run = Audio.longestQuietRun(interior, minimumLength: Int(sampleRate * 0.01))
        else { return 0 }
        return Double(run.length) / sampleRate
    }
}
