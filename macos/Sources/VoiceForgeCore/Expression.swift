import Foundation

/// A named starting point for a performance. The names are deliberately
/// familiar, but none of them is magic: each resolves to the model and tone
/// values in `recipe`. A listener can vary the intensity all the way back to
/// neutral rather than being trapped inside an opaque style switch.
public enum ExpressionPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case neutral
    case happy
    case playful
    case intimate
    case flirty
    case angry

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .neutral: "Neutral"
        case .happy: "Happy"
        case .playful: "Playful"
        case .intimate: "Intimate"
        case .flirty: "Flirty"
        case .angry: "Angry"
        }
    }

    public var note: String {
        switch self {
        case .neutral: "The reading the text asks for, with no colour on top."
        case .happy: "Quicker, brighter, and more of the sentence kept lit."
        case .playful: "The unevenest of them: weak words crushed, strong ones sprung."
        case .intimate: "Slow, close, and settled. Vowels held well past the point."
        case .flirty: "Unhurried, warm, and drawn out at the ends of phrases."
        case .angry: "Clipped and driven. Everything unstressed gets out of the way."
        }
    }

    /// Each expression is a different *reading*, not a filter over the same one.
    ///
    /// The earlier recipes moved pace by a few percent, nudged the two noise
    /// scales, and applied a shelf or two of EQ. None of it survived contact:
    /// the pace change was rounded away by the graph on 98% of tokens, the noise
    /// scales only redrew the dice, and broadband EQ reads to the ear as level
    /// rather than as character. What is left is the timing layer, plus a tint.
    fileprivate var recipe: ExpressionRecipe {
        switch self {
        case .neutral:
            ExpressionRecipe()
        case .happy:
            ExpressionRecipe(paceFactor: 0.93,
                             lowShelfDB: -1.5, presenceDB: 1.5, highShelfDB: 2.5,
                             prosody: ProsodySettings(focus: 1, phraseFinal: 0.1,
                                 deaccentRepeats: 0.25, contrast: 0.5,
                                 nucleusHold: 0.1, accentDB: 6, lift: 0.6))
        case .playful:
            ExpressionRecipe(paceFactor: 0.97,
                             lowShelfDB: -1, presenceDB: 2, highShelfDB: 2,
                             prosody: ProsodySettings(focus: 0.9, phraseFinal: 0.2,
                                 deaccentRepeats: 0.5, contrast: 1,
                                 nucleusHold: 0.35, accentDB: 5.5, lift: 0.7))
        case .intimate:
            ExpressionRecipe(paceFactor: 1.12,
                             lowShelfDB: 2.5, presenceDB: -1.5, highShelfDB: -2.5,
                             prosody: ProsodySettings(focus: 0.45, phraseFinal: 1,
                                 deaccentRepeats: 0.7, contrast: 0.05,
                                 nucleusHold: 0.6, accentDB: 2.5, lift: -0.6))
        case .flirty:
            ExpressionRecipe(paceFactor: 1.1,
                             lowShelfDB: 1.5, presenceDB: 0.8, highShelfDB: 1,
                             prosody: ProsodySettings(focus: 0.55, phraseFinal: 1,
                                 deaccentRepeats: 0.6, contrast: 0.1,
                                 nucleusHold: 0.7, accentDB: 3.5, lift: -0.3))
        case .angry:
            ExpressionRecipe(paceFactor: 0.9,
                             lowShelfDB: 1.5, presenceDB: 2.5, highShelfDB: 0.8,
                             prosody: ProsodySettings(focus: 1, phraseFinal: 0,
                                 deaccentRepeats: 0.3, contrast: 1,
                                 nucleusHold: 0, accentDB: 6, lift: 1))
        }
    }
}

/// The performance attached to one sentence.
public struct SentenceExpression: Equatable, Codable, Sendable {
    public var preset: ExpressionPreset
    /// Zero is neutral; one is the preset as designed.
    public var intensity: Double
    /// Time spent moving from the preceding sentence's tone into this one.
    public var transitionSeconds: Double

    public init(preset: ExpressionPreset = .neutral, intensity: Double = 1,
                transitionSeconds: Double = 0.18) {
        self.preset = preset
        self.intensity = Self.clamp(intensity, 0 ... 1)
        self.transitionSeconds = Self.clamp(transitionSeconds, 0 ... 1)
    }

    public static let neutral = SentenceExpression()

    public var tone: ExpressionTone {
        let r = preset.recipe
        let amount = Self.clamp(intensity, 0 ... 1)
        return ExpressionTone(lowShelfDB: r.lowShelfDB * amount,
                              presenceDB: r.presenceDB * amount,
                              highShelfDB: r.highShelfDB * amount,
                              outputDB: r.outputDB * amount)
    }

    /// Apply the part of the recipe that belongs *inside* Piper. These values
    /// remain sentence-wide because the stock ONNX graph accepts one scales
    /// vector per inference call.
    public func applying(to base: SynthesisSettings) -> SynthesisSettings {
        let r = preset.recipe
        let amount = Self.clamp(intensity, 0 ... 1)
        var out = base
        let pace = 1 + (r.paceFactor - 1) * amount
        out.lengthScale = Self.clamp(base.lengthScale * pace,
                                     SynthesisSettings.lengthScaleRange)
        // The noise scales used to move here too. They did not encode anything:
        // both change which draw comes out, so two takes of one preset already
        // differed by more than two presets did.
        return out
    }

    /// How this expression reads, at this intensity. At zero it is the reading
    /// the text would have got anyway.
    public var prosody: ProsodySettings {
        let r = preset.recipe
        let n = Self.clamp(intensity, 0 ... 1)
        let base = ProsodySettings()
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * n }
        return ProsodySettings(
            focus: mix(base.focus, r.prosody.focus),
            phraseFinal: mix(base.phraseFinal, r.prosody.phraseFinal),
            deaccentRepeats: mix(base.deaccentRepeats, r.prosody.deaccentRepeats),
            contrast: mix(base.contrast, r.prosody.contrast),
            nucleusHold: mix(base.nucleusHold, r.prosody.nucleusHold),
            accentDB: mix(base.accentDB, r.prosody.accentDB),
            lift: mix(base.lift, r.prosody.lift))
    }

    private static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

/// The audible post-synthesis part of an expression recipe.
public struct ExpressionTone: Equatable, Sendable {
    public var lowShelfDB: Double = 0
    public var presenceDB: Double = 0
    public var highShelfDB: Double = 0
    public var outputDB: Double = 0

    public init(lowShelfDB: Double = 0, presenceDB: Double = 0,
                highShelfDB: Double = 0, outputDB: Double = 0) {
        self.lowShelfDB = lowShelfDB; self.presenceDB = presenceDB
        self.highShelfDB = highShelfDB; self.outputDB = outputDB
    }

    public var isNeutral: Bool {
        lowShelfDB == 0 && presenceDB == 0 && highShelfDB == 0 && outputDB == 0
    }
}

private struct ExpressionRecipe {
    /// Global pace. Only values that clear the graph's per-token rounding are
    /// worth setting: below about ten percent nothing moves at all.
    var paceFactor: Double = 1
    var lowShelfDB: Double = 0
    var presenceDB: Double = 0
    var highShelfDB: Double = 0
    var outputDB: Double = 0
    /// How this expression reads — where the weight falls, and how hard.
    var prosody = ProsodySettings()
}

/// Offline, sample-rate-aware *linear* tone shaping. Two complete filter paths
/// run during a transition and are crossfaded with a smoothstep curve.
/// Deliberately no saturation, compressor, or naive pitch shifting: those are
/// audible effects, not a substitute for an expressive source voice.
public enum ExpressionDSP {
    public static func process(_ samples: [Float], from: ExpressionTone,
                               to: ExpressionTone, transitionSeconds: Double,
                               sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return samples }
        if from.isNeutral && to.isNeutral { return samples }

        var a = Chain(tone: from, rate: sampleRate)
        var b = Chain(tone: to, rate: sampleRate)
        let transition = min(samples.count, max(0, Int(transitionSeconds * sampleRate)))
        var out = [Float](repeating: 0, count: samples.count)
        for i in samples.indices {
            let x = Double(samples[i])
            let av = a.process(x)
            let bv = b.process(x)
            let linear = transition == 0 ? 1 : min(1, Double(i) / Double(transition))
            let mix = linear * linear * (3 - 2 * linear)
            out[i] = Float(av + (bv - av) * mix)
        }
        return out
    }

    private struct Chain {
        var low: Biquad
        var presence: Biquad
        var high: Biquad
        var gain: Double

        init(tone: ExpressionTone, rate: Double) {
            low = .shelf(low: true, frequency: min(180, rate * 0.2),
                         gainDB: tone.lowShelfDB, rate: rate)
            presence = .peak(frequency: min(1_800, rate * 0.35), q: 0.85,
                             gainDB: tone.presenceDB, rate: rate)
            high = .shelf(low: false, frequency: min(4_200, rate * 0.42),
                          gainDB: tone.highShelfDB, rate: rate)
            gain = pow(10, tone.outputDB / 20)
        }

        mutating func process(_ x: Double) -> Double {
            high.process(presence.process(low.process(x))) * gain
        }
    }

    private struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }

        static func peak(frequency: Double, q: Double, gainDB: Double,
                         rate: Double) -> Biquad {
            guard abs(gainDB) > 0.000_001 else { return Biquad() }
            let a = pow(10, gainDB / 40)
            let w = 2 * Double.pi * frequency / rate
            let alpha = sin(w) / (2 * q)
            return normalized(b0: 1 + alpha * a, b1: -2 * cos(w), b2: 1 - alpha * a,
                              a0: 1 + alpha / a, a1: -2 * cos(w), a2: 1 - alpha / a)
        }

        static func shelf(low: Bool, frequency: Double, gainDB: Double,
                          rate: Double) -> Biquad {
            guard abs(gainDB) > 0.000_001 else { return Biquad() }
            let a = pow(10, gainDB / 40)
            let w = 2 * Double.pi * frequency / rate
            let c = cos(w), alpha = sin(w) / sqrt(2), root = 2 * sqrt(a) * alpha
            if low {
                return normalized(
                    b0: a * ((a + 1) - (a - 1) * c + root),
                    b1: 2 * a * ((a - 1) - (a + 1) * c),
                    b2: a * ((a + 1) - (a - 1) * c - root),
                    a0: (a + 1) + (a - 1) * c + root,
                    a1: -2 * ((a - 1) + (a + 1) * c),
                    a2: (a + 1) + (a - 1) * c - root)
            }
            return normalized(
                b0: a * ((a + 1) + (a - 1) * c + root),
                b1: -2 * a * ((a - 1) + (a + 1) * c),
                b2: a * ((a + 1) + (a - 1) * c - root),
                a0: (a + 1) - (a - 1) * c + root,
                a1: 2 * ((a - 1) - (a + 1) * c),
                a2: (a + 1) - (a - 1) * c - root)
        }

        private static func normalized(b0: Double, b1: Double, b2: Double,
                                       a0: Double, a1: Double, a2: Double) -> Biquad {
            Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                   a1: a1 / a0, a2: a2 / a0)
        }
    }
}
