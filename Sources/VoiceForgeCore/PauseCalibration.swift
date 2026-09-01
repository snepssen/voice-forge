import Foundation

/// How long a comma is worth, measured rather than declared.
///
/// The question this app was asked to answer — *how long a pause does a `,`
/// add?* — has no answer in the model's configuration. Piper has no pause
/// table. A comma reaches the model as a phoneme like any other, and the
/// duration predictor decides on the spot how many frames to spend on it,
/// conditioned on everything around it. The only honest way to say what it is
/// worth is to render a line with the mark and the same line without it, and
/// look at the difference.
///
/// That is what this type holds: the result of doing that, per voice, over a
/// probe set, with the spread as well as the mean. The spread is the part that
/// matters — a mean of 180 ms means very little if the range is 90 to 400,
/// and the app should say so rather than print one confident number.
public struct PauseCalibration: Equatable, Sendable, Codable {

    /// One mark's measured worth, in seconds.
    public struct Mark: Equatable, Sendable, Codable, Identifiable {
        public var id: String { mark }
        /// The punctuation itself: "," ";" ":" "—" "." and "" for none.
        public var mark: String
        /// Mean added silence over the probe set, in seconds.
        public var mean: Double
        public var minimum: Double
        public var maximum: Double
        /// How many probe pairs went into it.
        public var samples: Int

        public var spread: Double { maximum - minimum }

        public init(mark: String, mean: Double, minimum: Double, maximum: Double, samples: Int) {
            self.mark = mark; self.mean = mean
            self.minimum = minimum; self.maximum = maximum; self.samples = samples
        }
    }

    /// Which voice this was measured on. A calibration does not transfer:
    /// the two voices were fine-tuned on different corpora and pause
    /// differently.
    public var voice: String
    /// The settings in force during measurement. `lengthScale` scales
    /// durations, so a calibration taken at 1.0 does not describe 1.3.
    public var lengthScale: Double
    public var marks: [Mark]
    /// What one extra padding phoneme at a clause break buys, in seconds.
    /// This is what turns the pads dial into a number the listener can read.
    public var secondsPerClausePad: Double
    public var measuredAt: Date

    public init(voice: String, lengthScale: Double, marks: [Mark],
                secondsPerClausePad: Double, measuredAt: Date = Date()) {
        self.voice = voice; self.lengthScale = lengthScale; self.marks = marks
        self.secondsPerClausePad = secondsPerClausePad; self.measuredAt = measuredAt
    }

    public func mark(_ m: String) -> Mark? { marks.first { $0.mark == m } }

    /// What the app should print beside the clause-pause dial.
    ///
    /// Deliberately a range, not a figure. Padding phonemes are spent by the
    /// duration predictor, which is conditioned on its surroundings, so the
    /// same dial buys different time in different sentences. Printing a single
    /// number would be the sort of confident wrongness this project is
    /// supposed to avoid.
    public func clausePauseDescription(pads: Int) -> String {
        guard let comma = mark(",") else { return "not measured yet" }
        guard pads > 0 else {
            return String(format: "about %.0f ms, as the model writes it", comma.mean * 1000)
        }
        let added = Double(pads) * secondsPerClausePad
        let low = (comma.minimum + added) * 1000
        let high = (comma.maximum + added) * 1000
        return String(format: "about %.0f ms, ranging %.0f–%.0f across the probe set",
                      (comma.mean + added) * 1000, low, high)
    }

    /// Whether this calibration still describes the settings in force.
    /// `lengthScale` multiplies durations, so a change to it invalidates
    /// everything here rather than merely shifting it.
    public func describes(_ settings: SynthesisSettings, voice name: String) -> Bool {
        voice == name && abs(lengthScale - settings.lengthScale) < 0.001
    }

    /// The probe set: pairs that differ only by the mark under test.
    ///
    /// Each pair is the same words with and without the punctuation, so the
    /// difference in the gap at that junction is the mark's contribution and
    /// nothing else. Kept short and ordinary — long or unusual sentences make
    /// the duration predictor do more interesting things, which is the
    /// opposite of what a calibration wants.
    public static func probes(for mark: String) -> [(with: String, without: String)] {
        let bodies: [(String, String)] = [
            ("The room was quiet", "and nobody moved"),
            ("She looked up", "then looked away"),
            ("It arrived on Tuesday", "which was too late"),
            ("Take the first turning", "then keep going"),
            ("He said nothing", "and that was answer enough"),
            ("The light changed", "so we crossed"),
        ]
        return bodies.map { first, second in
            (with: "\(first)\(mark) \(second).", without: "\(first) \(second).")
        }
    }
}
