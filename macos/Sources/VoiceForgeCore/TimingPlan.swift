import Foundation

/// Turning a direction about a word into a factor for every sound in it.
///
/// The model is addressed per token, so per-sound is the primitive here and
/// per-word is a selection over it: "hold this word" means "hold the sounds in
/// this word that can be held, by how much each one can take". Nothing else in
/// the sentence moves, which is checked rather than assumed — the experiment
/// asserts every untargeted token keeps its exact predicted frame count.
///
/// An accent is not a louder word. It is the stressed nucleus held longer than
/// the rest of its own word, with a level lift shaped around that nucleus.
/// Pitch is deliberately absent: every attempt to shift it on this voice was
/// rejected by ear, while the held vowel was the one result that was preferred.

/// One id as the model receives it, and what it is carrying.
public struct TokenSlot: Equatable, Sendable {
    public var index: Int
    /// The phoneme itself, or for a blank, the phoneme it trails.
    public var symbol: String
    public var kind: Kind
    /// Which spoken word it belongs to; -1 between or outside words.
    public var word: Int

    public enum Kind: String, Sendable {
        case symbol, blank, frame, trailing, clause, directed
    }

    public init(index: Int, symbol: String, kind: Kind, word: Int) {
        self.index = index
        self.symbol = symbol
        self.kind = kind
        self.word = word
    }
}

public struct TokenLayout: Equatable, Sendable {
    public var ids: [Int]
    public var slots: [TokenSlot]
    public var words: Int

    public init(ids: [Int], slots: [TokenSlot], words: Int) {
        self.ids = ids
        self.slots = slots
        self.words = words
    }
}

public struct SoundDirection: Equatable, Sendable {
    /// Index of the spoken word within this sentence's phoneme stream.
    public var word: Int
    /// 1 leaves the word alone. Above 1 holds it, weighted per sound.
    public var stretch: Double
    /// Extra hold on the stressed nucleus alone, on top of `stretch`.
    public var accent: Double
    /// Level lift across the word, in dB.
    public var accentDB: Double

    public init(word: Int, stretch: Double = 1, accent: Double = 0, accentDB: Double = 0) {
        self.word = word
        self.stretch = stretch
        self.accent = accent
        self.accentDB = accentDB
    }
}

public enum TimingPlan {
    /// What the harness accepts, and well inside where the graph stays sensible.
    public static let factorRange: ClosedRange<Double> = 0.5 ... 2.5

    /// The level a full accent is given, chosen by ear against +3 and +4.5 on
    /// the bundled voice. It is a listening decision, not a derived figure, so
    /// it sits here under its own name rather than appearing as a number at a
    /// call site — and like every other measurement in this app it belongs to
    /// the voice it was chosen on. Worst-case sample peak at this level was
    /// -4.11 dBFS, with no limiting, which is the headroom any change has to keep.
    public static let fullAccentDB: Double = 6

    /// One dial's worth of accent: hold and level move together, because an
    /// accent that is only long reads as a drawl and one that is only loud
    /// reads as a mistake. Strength runs 0 to 1.
    public static func accented(word: Int, stretch: Double, strength: Double) -> SoundDirection {
        let s = min(1, max(0, strength))
        return SoundDirection(word: word, stretch: stretch,
                              accent: 0.6 * s, accentDB: fullAccentDB * s)
    }

    /// Every token of one spoken word, blanks included, in the model's order.
    public static func wordSlots(_ layout: TokenLayout, word: Int) -> [TokenSlot] {
        layout.slots.filter { $0.word == word }
    }

    /// The word as it would be read aloud in IPA, for showing next to a dial.
    public static func wordPhonemes(_ layout: TokenLayout, word: Int) -> String {
        wordSlots(layout, word: word).filter { $0.kind == .symbol }
            .map(\.symbol).joined()
    }

    /// The vowel run an accent lands on: the one right after the primary stress
    /// mark, or — for the many one-syllable words espeak leaves unmarked, `juː`
    /// and `ɪt` among them — the word's first vowel run.
    public static func nucleus(_ layout: TokenLayout, word: Int) -> [TokenSlot] {
        let slots = wordSlots(layout, word: word)
        let symbols = slots.filter { $0.kind == .symbol }
        var start: Int
        if let stressed = symbols.firstIndex(where: { $0.symbol == String(Phonology.primaryStress) }) {
            start = stressed + 1
        } else if let vowel = symbols.firstIndex(where: { Phonology.isVowelish($0.symbol) }) {
            start = vowel
        } else {
            return []
        }
        guard start < symbols.count else { return [] }

        // Skip any articulatory marks sitting between the stress and its vowel.
        while start < symbols.count, Phonology.isStress(symbols[start].symbol) { start += 1 }
        var run: [TokenSlot] = []
        var i = start
        while i < symbols.count, Phonology.isVowelish(symbols[i].symbol) {
            run.append(symbols[i])
            i += 1
        }
        guard let first = run.first, let last = run.last else { return [] }

        // A blank carries real speech duration here, not silence, so the blank
        // trailing each vowel belongs to the vowel.
        return slots.filter {
            $0.index >= first.index && $0.index <= last.index + 1
                && ($0.kind == .symbol || $0.kind == .blank)
        }
    }

    /// One factor per token, aligned to `layout.ids` index for index.
    ///
    /// A blank inherits the class of the sound it trails, which is why the
    /// blank after a plosive stays at exactly one: that gap is the stop's
    /// closure, and stretching it is how a held word turns into a stutter.
    public static func durationFactors(_ layout: TokenLayout,
                                       _ directions: [SoundDirection]) -> [Float] {
        var factors = [Float](repeating: 1, count: layout.ids.count)
        var targeted: [Int: SoundDirection] = [:]
        for d in directions { targeted[d.word] = d }

        for (word, direction) in targeted {
            for slot in wordSlots(layout, word: word) {
                guard slot.kind == .symbol || slot.kind == .blank else { continue }
                let weight = Phonology.phonemeClass(slot.symbol).susceptibility
                guard weight > 0 else { continue }
                factors[slot.index] = Float(clamp(1 + (direction.stretch - 1) * weight))
            }
            guard direction.accent > 0 else { continue }
            for slot in nucleus(layout, word: word) {
                let weight = Phonology.phonemeClass(slot.symbol).susceptibility
                guard weight > 0 else { continue }
                factors[slot.index] = Float(clamp(Double(factors[slot.index])
                    + direction.accent * weight))
            }
        }
        return factors
    }

    /// Where each token begins and ends in the rendered audio, from the frame
    /// counts the model reports back. This is the model's own alignment, not a
    /// guess from a recogniser — which is the whole reason it can be trusted.
    public static func sampleBounds(_ frames: [Float], hop: Int) -> [Int] {
        var bounds = [0]
        var total = 0.0
        for frame in frames {
            total += Double(frame)
            bounds.append(Int(total) * hop)
        }
        return bounds
    }

    /// The level lift over each accented word.
    ///
    /// Shaped around the nucleus rather than the word: the lift reaches full
    /// value across the stressed vowel and ramps either side of it. A single
    /// cosine over the whole word peaks at the word's midpoint, which lands on
    /// a consonant as often as not — the lift was then loudest where the accent
    /// was not, which reads as subtle however many dB it is given.
    ///
    /// Linear gain only, no compression. The ramps never run shorter than a
    /// frame, so a word that opens straight onto its vowel still rises into the
    /// lift instead of stepping into it.
    public static func accentEnvelope(_ layout: TokenLayout, _ directions: [SoundDirection],
                                      frames: [Float], samples: Int, hop: Int) -> [Float] {
        var envelope = [Float](repeating: 1, count: samples)
        let bounds = sampleBounds(frames, hop: hop)
        func at(_ index: Int) -> Int {
            let i = min(max(index, 0), bounds.count - 1)
            return min(max(bounds[i], 0), samples)
        }

        for direction in directions {
            guard direction.accentDB != 0 else { continue }
            let slots = wordSlots(layout, word: direction.word)
            guard let firstSlot = slots.first, let lastSlot = slots.last else { continue }
            let wordStart = at(firstSlot.index)
            let wordEnd = at(lastSlot.index + 1)
            guard wordEnd - wordStart > 1 else { continue }

            let core = nucleus(layout, word: direction.word)
            var holdStart = core.first.map { at($0.index) } ?? wordStart
            var holdEnd = core.last.map { at($0.index + 1) } ?? wordEnd
            // Borrow a frame from the nucleus when there is no onset or coda to
            // ramp across, rather than stepping the gain and clicking.
            if holdStart - wordStart < hop { holdStart = min(holdEnd, wordStart + hop) }
            if wordEnd - holdEnd < hop { holdEnd = max(holdStart, wordEnd - hop) }

            let peak = pow(10, direction.accentDB / 20) - 1
            for i in wordStart ..< holdStart {
                let phase = Double(i - wordStart) / Double(max(1, holdStart - wordStart))
                envelope[i] = Float(1 + peak * 0.5 * (1 - cos(.pi * phase)))
            }
            for i in holdStart ..< holdEnd { envelope[i] = Float(1 + peak) }
            for i in holdEnd ..< wordEnd {
                let phase = Double(i - holdEnd) / Double(max(1, wordEnd - holdEnd))
                envelope[i] = Float(1 + peak * 0.5 * (1 + cos(.pi * phase)))
            }
        }
        return envelope
    }

    /// What a direction actually bought, for printing next to the dial rather
    /// than asserting a figure that was measured on some other voice.
    public static func addedSeconds(base: [Float], actual: [Float],
                                    hop: Int, rate: Double) -> Double {
        var added = 0.0
        for (i, value) in base.enumerated() {
            added += Double((i < actual.count ? actual[i] : 0) - value)
        }
        return added * Double(hop) / rate
    }

    private static func clamp(_ v: Double) -> Double {
        min(factorRange.upperBound, max(factorRange.lowerBound, v))
    }
}
