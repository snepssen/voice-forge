import Foundation

/// Every dial, with the range it is honest over and the reason it exists.
///
/// Gateway Forge settles these and never shows them: a meditation tape wants
/// one voice that does not drift under the listener. This app is the other
/// half of the same engine — the same three numbers, on the outside, where a
/// voiceover can be shaped by them.
public struct SynthesisSettings: Equatable, Sendable, Codable {

    // MARK: the three scales the model takes

    /// Pace. The model's frame allocation is multiplied by this, so 1.1 is ten
    /// percent slower and 0.9 ten percent faster.
    ///
    /// **1.0 means "as trained", and what that is worth depends on the voice.**
    /// On `snepssen-rode` it is a measured likeness: 60 rendered lines against
    /// the reader's own recordings of the same text gave an articulation rate
    /// ratio of 1.0034, so the model says words at the reader's own rate to
    /// within a third of one percent. The voice bundled here was fine-tuned on
    /// generated audio instead, and on identical copy reads **31% faster** —
    /// 194 words a minute against 148. See `VoiceNotes`, which is where the
    /// per-voice claim lives, precisely so that one voice's measurement cannot
    /// be printed under the other.
    public var lengthScale: Double = 1.0

    /// How much the acoustic model varies between draws. Piper's default,
    /// carried in the voice config.
    ///
    /// Lower is flatter and more repeatable; higher is more expressive and
    /// less predictable. It does **not** change pace or pausing — a common
    /// misreading, and the reason this is labelled variation rather than
    /// "expression".
    public var noiseScale: Double = 0.667

    /// How much the *durations* vary between draws — the cadence, as distinct
    /// from the timbre. Raising it makes successive takes of the same line
    /// differ in rhythm; lowering it toward zero makes them near-identical
    /// and noticeably mechanical.
    public var noiseW: Double = 0.8

    // MARK: pauses, in seconds

    /// Silence laid between two sentences, on top of whatever the model
    /// already leaves. Exact, because sentences really are separate inference
    /// calls and this is real silence inserted between them.
    public var sentenceGap: Double = 0.08

    /// Silence at a paragraph break, replacing the sentence gap there.
    public var paragraphGap: Double = 0.55

    /// Extra room given to the model at a clause break — a comma, semicolon,
    /// colon or em dash.
    ///
    /// **Not measured in seconds, and that is the honest unit.** A clause break
    /// happens *inside* one inference call, so it cannot be lengthened by
    /// splicing silence without cutting the sentence in two — which is exactly
    /// the cut that produced a stutter at the seam. What can be done instead is
    /// to hand the model more padding phonemes at that position and let its own
    /// duration predictor spend them, which is in-distribution and seamless.
    ///
    /// The cost is that a pad is not a fixed number of milliseconds: what it
    /// buys depends on the voice and on the surrounding phonemes. So the app
    /// measures it — see `PauseCalibration` — and shows the measured
    /// milliseconds beside the pad count rather than pretending the dial is in
    /// time units.
    public var clausePads: Int = 0

    /// Extra padding phonemes before the end of an utterance.
    ///
    /// **2 is a measured optimum, not a floor to raise.** These voices end on
    /// residual breath rather than decaying to silence — an artifact of a
    /// fine-tuning corpus trimmed tight — and the padding gives the decay
    /// somewhere to land. Over 7 lines x 5 runs x 4 variants, worst-case 60 ms
    /// tail RMS: 0.00605 at zero pads, 0.00246 at one, **0.00079 at two**,
    /// 0.00336 at three. It is not monotonic. Three is worse than two, because
    /// too much room lets the model start voicing into it.
    public var trailingPads: Int = 2

    /// Drop the final full stop before the end of an utterance.
    ///
    /// These voices learned "the recording stops here" at the `.` phoneme and
    /// reproduce whatever sat at that cut — heard as a phantom consonant after
    /// the words finish, a `t` after "Cluster Council", an `sh` after "I
    /// welcome connection". Over 12 final sentences x 8 draws, two pads with
    /// the stop dropped scored 0.0% artifacts against 1.0% with it kept, and
    /// the sentence-final fall survives. Only `.` — `?` and `!` carry
    /// intonation worth keeping.
    public var dropFinalFullStop: Bool = true

    /// Read `$4.99` as "four dollars ninety-nine" rather than as espeak's
    /// "dollar four point nine nine".
    ///
    /// On by default because the alternative is wrong in every currency, and
    /// switchable because it is the one place this app rewrites the words it
    /// was given. See `Script.spokenCurrency`.
    public var spokenCurrency: Bool = true

    public init() {}

    // MARK: ranges

    /// The range each dial is offered over, and what the ends mean. Kept here
    /// rather than in the view so a check can assert the defaults sit inside
    /// their own ranges — which is the sort of thing that silently stops being
    /// true after an edit.
    public static let lengthScaleRange = 0.5 ... 2.0
    public static let noiseScaleRange = 0.0 ... 1.5
    public static let noiseWRange = 0.0 ... 1.5
    public static let sentenceGapRange = 0.0 ... 2.0
    public static let paragraphGapRange = 0.0 ... 4.0
    public static let clausePadsRange = 0 ... 12
    public static let trailingPadsRange = 0 ... 6

    /// Whether every value sits inside the range the app offers it over.
    public var isWithinRanges: Bool {
        Self.lengthScaleRange.contains(lengthScale)
            && Self.noiseScaleRange.contains(noiseScale)
            && Self.noiseWRange.contains(noiseW)
            && Self.sentenceGapRange.contains(sentenceGap)
            && Self.paragraphGapRange.contains(paragraphGap)
            && Self.clausePadsRange.contains(clausePads)
            && Self.trailingPadsRange.contains(trailingPads)
    }

    /// The values the voice config ships with, which is what Gateway Forge
    /// uses and never changes. Offered as a labelled starting point rather
    /// than buried as "reset".
    public static var voiceDefaults: SynthesisSettings { SynthesisSettings() }

    // The pace note lives in `VoiceNotes`, not here. It has to name the voice
    // it was measured on: the 0.3% figure is real but was measured on
    // snepssen-rode, and the bundled voice reads 31% faster on identical copy.
    // Printing one voice's measurement under the other was false.
}
