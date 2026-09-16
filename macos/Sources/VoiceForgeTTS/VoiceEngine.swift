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
    public var expressionKey: String
    public var expression: SentenceExpression
    public var text: String
    public var samples: [Float]
    /// Silence laid *after* this sentence before the next one begins.
    public var trailingGap: Double
    public var seconds: Double
    public var peakDBFS: Double
    /// Words per minute over this sentence alone, silence included.
    public var wordsPerMinute: Double

    public init(id: Int, expressionKey: String = "",
                expression: SentenceExpression = .neutral,
                text: String, samples: [Float], trailingGap: Double,
                seconds: Double, peakDBFS: Double, wordsPerMinute: Double) {
        self.id = id; self.expressionKey = expressionKey; self.expression = expression
        self.text = text; self.samples = samples
        self.trailingGap = trailingGap; self.seconds = seconds
        self.peakDBFS = peakDBFS; self.wordsPerMinute = wordsPerMinute
    }
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
    private var defaultPhonemeCache: [String: String] = [:]

    /// The rate this model actually speaks at, read from its own config.
    public var sampleRate: Double { Double(config.audio.sample_rate) }

    /// Every voice available: the one that ships, plus anything installed.
    ///
    /// One voice ships and it is not privileged. An installed voice of the same
    /// name wins, so somebody who retrains `snepssen` gets theirs without
    /// having to pick a different name to escape ours.
    public static func availableVoices() -> [VoiceProfile] {
        VoiceLibrary.merge(bundled: bundledProfiles(), installed: installedProfiles().voices)
    }

    public static func bundledProfiles() -> [VoiceProfile] {
        guard let dir = Bundle.module.resourceURL,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return VoiceLibrary.scan(files: files, in: dir, bundled: true).voices
    }

    /// What is in the user's voices folder, and what is wrong with the rest.
    /// The rejections are surfaced: somebody who has just trained a model and
    /// copied one of its two files deserves to be told which is missing.
    public static func installedProfiles()
        -> (voices: [VoiceProfile], rejected: [VoiceRejection]) {
        let dir = AppDirectories.voices
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return ([], []) }
        return VoiceLibrary.scan(files: files, in: dir, bundled: false)
    }

    /// The espeak-ng data, which every voice shares. Bundled, not per voice —
    /// a Piper export carries a model and a config, never the phonemizer.
    public static func espeakDataDirectory() -> URL? {
        Bundle.module.url(forResource: "espeak-ng-data", withExtension: nil)
    }

    public convenience init(voice: String) throws {
        guard let profile = Self.availableVoices().first(where: { $0.name == voice })
        else { throw VoiceEngineError.noModel(voice) }
        try self.init(profile: profile)
    }

    public init(profile: VoiceProfile) throws {
        guard let env = Self.env else { throw VoiceEngineError.noEnvironment }
        self.voice = profile.name
        guard let dataDir = Self.espeakDataDirectory() else {
            throw VoiceEngineError.noModel(profile.name)
        }
        config = try JSONDecoder().decode(PiperVoiceConfig.self,
                                          from: Data(contentsOf: profile.configURL))
        session = try ORTSession(env: env, modelPath: profile.modelURL.path, sessionOptions: nil)
        phonemizer = try EspeakPhonemizer(dataDirectory: dataDir, voice: config.espeak.voice)
    }

    // MARK: rendering

    /// Render a whole script, sentence by sentence, laying the requested
    /// silence between them.
    public func render(_ script: Script, settings: SynthesisSettings,
                       dictionary: [PronunciationEntry] = [],
                       expressions: [String: SentenceExpression] = [:],
                       onSentence: ((Int, Int) -> Void)? = nil) throws -> [RenderedSentence] {
        var out: [RenderedSentence] = []
        var previousTone = SentenceExpression.neutral.tone
        // What the paragraph has already said, so a word is not hit twice. It
        // is the paragraph and not the script: a word returning after a break
        // is new again to a listener.
        var spoken: Set<String> = []
        var paragraph = script.sentences.first?.paragraph ?? 0
        for (i, sentence) in script.sentences.enumerated() {
            onSentence?(i, script.sentences.count)
            if sentence.paragraph != paragraph { spoken = []; paragraph = sentence.paragraph }
            let expression = expressions[sentence.expressionKey] ?? .neutral
            let sentenceSettings = expression.applying(to: settings)
            let readingSettings = expression.prosody
            let directions = reading(for: sentence.text, settings: sentenceSettings,
                                     dictionary: dictionary, spoken: spoken,
                                     prosody: readingSettings)
            let raw = try renderSentence(sentence.text, settings: sentenceSettings,
                                         dictionary: dictionary, directions: directions,
                                         lift: readingSettings.lift)
            spoken.formUnion(spokenKeys(for: sentence.text, settings: sentenceSettings,
                                        dictionary: dictionary))
            let samples = ExpressionDSP.process(raw, from: previousTone,
                                                to: expression.tone,
                                                transitionSeconds: expression.transitionSeconds,
                                                sampleRate: sampleRate)
            previousTone = expression.tone
            // The gap that follows this sentence. A paragraph break replaces
            // the sentence gap rather than adding to it -- two silences laid
            // end to end is how a "0.6 s paragraph" quietly becomes 0.68.
            let gap: Double = i == script.sentences.count - 1
                ? 0
                : (sentence.endsParagraph ? settings.paragraphGap : settings.sentenceGap)
            let seconds = Audio.seconds(samples, at: sampleRate)
            let words = PerformanceMarkup.wordCount(sentence.text)
            out.append(RenderedSentence(
                id: sentence.id, expressionKey: sentence.expressionKey,
                expression: expression, text: sentence.text, samples: samples,
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

    /// Whether this voice can be told how long each sound should last.
    ///
    /// The bundled voice's graph carries an extra input for it. A voice
    /// somebody added themselves will not, and asks nothing of them: it renders
    /// exactly as it always did, and the timing controls have nothing to
    /// address rather than failing.
    public var directsTiming: Bool {
        ((try? session.inputNames()) ?? []).contains(Self.durationFactorsInput)
    }

    /// How this sentence should be read, if nobody has said otherwise.
    ///
    /// Empty when the setting is off or the voice cannot be told its timing, so
    /// the caller never has to ask which of those is the case.
    public func reading(for text: String, settings: SynthesisSettings,
                        dictionary: [PronunciationEntry] = [],
                        spoken: Set<String> = [],
                        prosody: ProsodySettings = ProsodySettings()) -> [SoundDirection] {
        guard settings.automaticDynamics, directsTiming else { return [] }
        return Prosody.automaticDirections(
            layout(for: text, settings: settings, dictionary: dictionary, lift: prosody.lift),
            settings: prosody, spoken: spoken)
    }

    /// The tokens one sentence becomes, after any lift has moved its stress marks.
    ///
    /// Everything that needs a layout comes through here. A direction addresses
    /// a token by index, so if the reading were planned against one phoneme
    /// string and the audio rendered from another, every hold would land on the
    /// wrong sound — and a lift changes the string.
    private func layout(for text: String, settings: SynthesisSettings,
                        dictionary: [PronunciationEntry], lift: Double) -> TokenLayout {
        let phonemized = preparedPhonemes(for: text, settings: settings,
                                          dictionary: dictionary).encoded
        return tokenLayout(Phonology.restress(phonemized, lift: lift), settings: settings)
    }

    /// The words this sentence has now said, to carry into the next one.
    public func spokenKeys(for text: String, settings: SynthesisSettings,
                           dictionary: [PronunciationEntry] = []) -> Set<String> {
        let phonemized = preparedPhonemes(for: text, settings: settings,
                                          dictionary: dictionary).encoded
        return Prosody.spokenKeys(tokenLayout(phonemized, settings: settings))
    }

    /// One sentence, one inference call. Never less, never more.
    public func renderSentence(_ text: String, settings: SynthesisSettings,
                               dictionary: [PronunciationEntry] = [],
                               directions: [SoundDirection] = [],
                               lift: Double = 0) throws -> [Float] {
        try renderTimed(text, settings: settings, dictionary: dictionary,
                        directions: directions, lift: lift).samples
    }

    /// The same call, keeping what the model said about its own timing.
    ///
    /// The frame counts come back from the graph rather than from a recogniser
    /// guessing at word boundaries, so an accent's level can be laid over the
    /// exact samples of the sound it belongs to.
    public func renderTimed(_ text: String, settings: SynthesisSettings,
                            dictionary: [PronunciationEntry] = [],
                            directions: [SoundDirection] = [], lift: Double = 0)
        throws -> (samples: [Float], layout: TokenLayout, frames: [Float]) {
        let layout = layout(for: text, settings: settings, dictionary: dictionary, lift: lift)
        guard !layout.ids.isEmpty else { return ([], layout, []) }

        // A vector of ones is not a no-op we hope for -- it is the patch's
        // defining property, checked against the unpatched graph.
        let factors = directsTiming ? TimingPlan.durationFactors(layout, directions) : []
        let result = try infer(ids: layout.ids, settings: settings, factors: factors)

        var samples = result.samples
        if !result.frames.isEmpty, directions.contains(where: { $0.accentDB != 0 }) {
            let total = result.frames.reduce(0) { $0 + Double($1) }
            let hop = total > 0 ? Int((Double(samples.count) / total).rounded()) : 256
            let gain = TimingPlan.accentEnvelope(layout, directions, frames: result.frames,
                                                 samples: samples.count, hop: max(1, hop))
            for i in samples.indices { samples[i] *= gain[i] }
        }
        return (samples, layout, result.frames)
    }

    /// The phonemes a sentence will actually be spoken from, with the
    /// dictionary applied, and which entries landed.
    ///
    /// `applied` is reported rather than assumed. The substitution finds a
    /// word by phonemizing it on its own and matching that in the sentence,
    /// which holds for ordinary prose -- "Kubrick" alone is `kˈʌbɹɪk` and it
    /// appears verbatim in "I watched a Kubrick film" -- but stress can move in
    /// context, and an entry that quietly does nothing is exactly the failure
    /// this whole feature exists to stop.
    public func phonemes(for text: String, settings: SynthesisSettings,
                         dictionary: [PronunciationEntry] = [])
        -> (phonemes: String, applied: Set<String>) {
        let prepared = preparedPhonemes(for: text, settings: settings, dictionary: dictionary)
        return (prepared.display, prepared.applied)
    }

    private struct PreparedPhonemes {
        var encoded: String
        var display: String
        var applied: Set<String>
    }

    // Private-use markers never reach the model as symbols. `phonemeIDs`
    // turns them into extra PAD ids inside the one utterance.
    private static let shortBeatMarker = "\u{E000}"
    private static let mediumBeatMarker = "\u{E001}"
    private static let longBeatMarker = "\u{E002}"
    private static let focusBoundaryMarker = "\u{E003}"

    private func preparedPhonemes(for text: String, settings: SynthesisSettings,
                                  dictionary: [PronunciationEntry]) -> PreparedPhonemes {
        let tokens = PerformanceMarkup.parse(text)
        var defaults: [String: String] = [:]
        for entry in dictionary {
            defaults[entry.key] = defaultPhonemes(for: entry.word)
        }

        var encoded: [String] = []
        var applied: Set<String> = []
        var run: [PerformanceToken] = []

        func appendRun(dropFinalStop: Bool) {
            guard !run.isEmpty else { return }
            var source = ""
            var focusRanges: [Range<Int>] = []
            for token in run {
                guard case .text(let raw, let focused) = token else { continue }
                let piece = settings.spokenCurrency ? Script.spokenCurrency(raw) : raw
                let start = source.split(whereSeparator: \.isWhitespace).count
                source += piece
                if focused {
                    let end = source.split(whereSeparator: \.isWhitespace).count
                    if end > start { focusRanges.append(start ..< end) }
                }
            }

            // A focus mark must not cause the unmarked words either side to be
            // phonemized as separate mini-phrases. The clean run goes through
            // espeak once; focus is then located by word-group ordinal.
            var base = (try? phonemizer.phonemize(source, dropFinalStop: dropFinalStop)) ?? ""
            if !dictionary.isEmpty {
                let result = PronunciationDictionary.apply(dictionary, to: base,
                                                           defaults: defaults)
                base = result.phonemes
                applied.formUnion(result.applied)
            }
            guard !base.isEmpty else { run = []; return }

            var groups = base.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            for range in focusRanges.reversed() {
                guard range.lowerBound < groups.count else { continue }
                let upper = min(range.upperBound, groups.count)
                let focused = groups[range.lowerBound ..< upper].joined(separator: " ")
                let marked = Self.focusBoundaryMarker + Self.promotingFocus(in: focused)
                    + Self.focusBoundaryMarker
                groups.replaceSubrange(range.lowerBound ..< upper, with: [marked])
            }
            encoded.append(groups.joined(separator: " "))
            run = []
        }

        for token in tokens {
            switch token {
            case .beat(let beat):
                appendRun(dropFinalStop: false)
                switch beat {
                case .short: encoded.append(Self.shortBeatMarker)
                case .medium: encoded.append(Self.mediumBeatMarker)
                case .long: encoded.append(Self.longBeatMarker)
                }
            case .text:
                run.append(token)
            }
        }
        appendRun(dropFinalStop: settings.dropFinalFullStop)

        let value = encoded.joined(separator: " ")
        var display = value.replacingOccurrences(of: Self.shortBeatMarker, with: "⟨short beat⟩")
        display = display.replacingOccurrences(of: Self.mediumBeatMarker, with: "⟨beat⟩")
        display = display.replacingOccurrences(of: Self.longBeatMarker, with: "⟨long beat⟩")
        display = display.replacingOccurrences(of: Self.focusBoundaryMarker, with: "")
        return PreparedPhonemes(encoded: value, display: display, applied: applied)
    }

    /// Promote secondary stress when available; otherwise give an unstressed
    /// focused run a primary-stress cue. Already-primary words are left alone.
    private static func promotingFocus(in phonemes: String) -> String {
        if phonemes.contains("ˈ") { return phonemes }
        if let secondary = phonemes.range(of: "ˌ") {
            var out = phonemes
            out.replaceSubrange(secondary, with: "ˈ")
            return out
        }
        var groups = phonemes.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if let index = groups.firstIndex(where: { $0.contains(where: \.isLetter) }) {
            groups[index] = "ˈ" + groups[index]
        }
        return groups.joined(separator: " ")
    }

    /// What espeak says for a word on its own. Cached: a script re-rendered
    /// with a ten-word dictionary would otherwise phonemize those ten words
    /// once per sentence.
    public func defaultPhonemes(for word: String) -> String {
        let key = word.lowercased()
        if let cached = defaultPhonemeCache[key] { return cached }
        let value = (try? phonemizer.phonemize(word, dropFinalStop: false)) ?? ""
        defaultPhonemeCache[key] = value
        return value
    }

    /// The symbols this voice knows, as a set, for validating a typed entry.
    public var vocabularySet: Set<String> {
        Set(config.phoneme_id_map.keys.filter { $0.count == 1 })
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
        tokenLayout(phonemized, settings: settings).ids
    }

    /// The same ids, with a parallel account of what each one is.
    ///
    /// Per-sound timing needs a factor for every token the model receives, in
    /// the model's order, so it needs to know which token is the vowel and
    /// which is the blank trailing it. Deriving both from one loop is the
    /// point: a separate reconstruction of this layout could drift from the ids
    /// actually sent, and a factor vector that has drifted holds the wrong sound.
    func tokenLayout(_ phonemized: String, settings: SynthesisSettings) -> TokenLayout {
        let map = config.phoneme_id_map
        let pad = map["_"] ?? []
        var ids: [Int] = []
        var slots: [TokenSlot] = []
        var word = 0

        func push(_ values: [Int], _ symbol: String, _ kind: TokenSlot.Kind, _ w: Int) {
            for id in values {
                slots.append(TokenSlot(index: ids.count, symbol: symbol, kind: kind, word: w))
                ids.append(id)
            }
        }

        push(map["^"] ?? [], "^", .frame, -1)
        push(pad, "^", .blank, -1)

        for scalar in phonemized.unicodeScalars {
            let key = String(scalar)
            let directedPads: Int? = switch key {
            case Self.shortBeatMarker: PerformanceBeat.short.pads
            case Self.mediumBeatMarker: PerformanceBeat.medium.pads
            case Self.longBeatMarker: PerformanceBeat.long.pads
            case Self.focusBoundaryMarker: 2
            default: nil
            }
            if let directedPads {
                for _ in 0 ..< directedPads { push(pad, key, .directed, -1) }
                continue
            }
            guard let id = map[key] else { continue }
            // A space separates words and belongs to neither, so the count
            // advances after it rather than handing the gap to the word that
            // just ended.
            let spoken = key != " "
            push(id, key, .symbol, spoken ? word : -1)
            push(pad, key, .blank, spoken ? word : -1)
            if settings.clausePads > 0,
               let ch = key.first, Script.clauseMarks.contains(ch) {
                for _ in 0 ..< settings.clausePads { push(pad, key, .clause, -1) }
            }
            if !spoken { word += 1 }
        }
        for _ in 0 ..< settings.trailingPads { push(pad, "$", .trailing, -1) }
        push(map["$"] ?? [], "$", .frame, -1)
        return TokenLayout(ids: ids, slots: slots, words: word + 1)
    }

    static let durationFactorsInput = "vf_duration_factors"
    static let baseFramesOutput = "vf_base_frames"
    /// The exporter's own name for the rounded durations, kept as the patch
    /// found it rather than renamed.
    static let actualFramesOutput = "/Ceil_output_0"

    private func infer(ids: [Int], settings: SynthesisSettings,
                       factors: [Float] = []) throws -> (samples: [Float], frames: [Float]) {
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

        var inputs = ["input": inputTensor, "input_lengths": lengthTensor,
                      "scales": scalesTensor]
        if !factors.isEmpty {
            var values = factors
            let factorData = NSMutableData(bytes: &values,
                                           length: values.count * MemoryLayout<Float>.size)
            inputs[Self.durationFactorsInput] = try ORTValue(
                tensorData: factorData, elementType: .float,
                shape: [1, 1, NSNumber(value: values.count)])
        }

        let available = Set(((try? session.outputNames()) ?? []))
        var wanted: Set<String> = ["output"]
        if available.contains(Self.actualFramesOutput) { wanted.insert(Self.actualFramesOutput) }

        let outputs = try session.run(withInputs: inputs, outputNames: wanted, runOptions: nil)
        guard let tensor = outputs["output"], let data = try tensor.tensorData() as Data?
        else { throw VoiceEngineError.noOutput }

        func floats(_ value: ORTValue?) -> [Float] {
            guard let value, let data = try? value.tensorData() as Data else { return [] }
            let count = data.count / MemoryLayout<Float>.size
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        }
        return (floats(tensor), floats(outputs[Self.actualFramesOutput]))
    }

    /// The IPA a piece of text will actually be spoken from.
    ///
    /// Routed through the same path the renderer uses, settings and all. It
    /// used to call the phonemizer directly, which meant it reported what
    /// espeak said rather than what the model would hear -- so with the
    /// currency rule on it showed "dollar four point nine nine" for text the
    /// renderer was correctly saying as "four dollars ninety-nine". A
    /// diagnostic that disagrees with the thing it is diagnosing is worse than
    /// no diagnostic.
    public func phonemesFor(_ text: String,
                            settings: SynthesisSettings = SynthesisSettings()) -> String {
        phonemes(for: text, settings: settings).phonemes
    }

    /// Which symbols in a phoneme string the model actually knows.
    ///
    /// **This is the hazard any pronunciation feature has to answer for.**
    /// `phonemeIDs` skips an unknown symbol silently -- `guard let id =
    /// map[key] else { continue }` -- so a phoneme string containing anything
    /// outside the model's 161-symbol vocabulary loses those sounds with no
    /// error anywhere. Typing an ASCII `r` where IPA wants `ɹ`, or an `ʁ` this
    /// voice never learned, produces a word with a hole in it and no complaint.
    public func vocabularyCheck(_ phonemes: String) -> (kept: Int, dropped: [String]) {
        let map = config.phoneme_id_map
        let audible = phonemes
            .replacingOccurrences(of: "⟨short beat⟩", with: "")
            .replacingOccurrences(of: "⟨beat⟩", with: "")
            .replacingOccurrences(of: "⟨long beat⟩", with: "")
        var kept = 0
        var dropped: [String] = []
        for scalar in audible.unicodeScalars {
            let key = String(scalar)
            if map[key] != nil { kept += 1 }
            else if key != " " { dropped.append(key) }
        }
        return (kept, dropped)
    }

    /// Every symbol this voice can say, sorted. The alphabet a pronunciation
    /// field is allowed to use.
    public var vocabulary: [String] {
        config.phoneme_id_map.keys.filter { $0.count == 1 }.sorted()
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
