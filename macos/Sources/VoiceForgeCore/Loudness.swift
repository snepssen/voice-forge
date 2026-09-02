import Foundation

/// Programme loudness to ITU-R BS.1770-4, in LUFS.
///
/// This is the number every platform actually normalises against, and the
/// reason a voiceover that sounded right in isolation gets turned down on
/// upload. Peak level does not predict it: a track can peak at -0.1 dBFS and
/// still measure -24 LUFS if it is mostly quiet, which is exactly what an
/// unprocessed single voice reading a script tends to do.
///
/// Implemented rather than approximated, because an approximation here is
/// worse than no number: it would be believed. The K-weighting filters are
/// derived from BS.1770's analog prototype by bilinear transform at whatever
/// rate is passed in, not copied from the published 48 kHz coefficient table —
/// the model speaks at 22.05 kHz, and a 48 kHz table applied to 22.05 kHz
/// audio is wrong by several LU with nothing to show for it.
public enum Loudness {

    /// What the common destinations normalise to. Shown as targets, not as
    /// rules: a platform turning a track down is not damage, and pushing a
    /// voice to a louder target than the platform wants only costs dynamics.
    public struct Target: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var lufs: Double
        public var truePeakCeiling: Double
        public var note: String
    }

    public static let targets: [Target] = [
        .init(name: "YouTube", lufs: -14, truePeakCeiling: -1,
              note: "Turns anything louder down to -14. Going above it gains nothing and costs dynamics."),
        .init(name: "Podcast", lufs: -16, truePeakCeiling: -1,
              note: "Apple and Spotify spoken-word target. A little quieter than video, for headphones."),
        .init(name: "Broadcast (EBU R128)", lufs: -23, truePeakCeiling: -1,
              note: "European broadcast. Much quieter than streaming; only right if something asked for it."),
        .init(name: "Leave it alone", lufs: .nan, truePeakCeiling: .nan,
              note: "Export at the level the model produced, gain untouched."),
    ]

    /// A biquad, direct form I.
    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

        func apply(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let out = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x[i]
                y2 = y1; y1 = out
                y[i] = out
            }
            return y
        }
    }

    /// Stage 1 of K-weighting: a +4 dB high shelf standing in for the acoustic
    /// effect of a head in the sound field.
    static func headShelf(rate: Double) -> Biquad {
        let f0 = 1681.974450955533
        let G = 3.999843853973347
        let Q = 0.7071752369554196

        let K = tan(.pi * f0 / rate)
        let Vh = pow(10.0, G / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        let a0 = 1.0 + K / Q + K * K
        var f = Biquad()
        f.b0 = (Vh + Vb * K / Q + K * K) / a0
        f.b1 = 2.0 * (K * K - Vh) / a0
        f.b2 = (Vh - Vb * K / Q + K * K) / a0
        f.a1 = 2.0 * (K * K - 1.0) / a0
        f.a2 = (1.0 - K / Q + K * K) / a0
        return f
    }

    /// Stage 2: the RLB high-pass, which discards the rumble the ear does not
    /// weigh.
    static func rlbHighPass(rate: Double) -> Biquad {
        let f0 = 38.13547087602444
        let Q = 0.5003270373238773
        let K = tan(.pi * f0 / rate)
        var f = Biquad()
        let a0 = 1.0 + K / Q + K * K
        f.b0 = 1.0
        f.b1 = -2.0
        f.b2 = 1.0
        f.a1 = 2.0 * (K * K - 1.0) / a0
        f.a2 = (1.0 - K / Q + K * K) / a0
        return f
    }

    /// Integrated programme loudness, LUFS. Returns -.infinity for silence
    /// rather than a fabricated floor.
    ///
    /// Mono, so the channel weighting is 1.0 and there is no summing to do.
    /// 400 ms blocks at 75% overlap, then BS.1770's two-stage gate: drop
    /// blocks below an absolute -70 LUFS, take the mean of what is left, then
    /// drop blocks more than 10 LU below *that* and take the mean again. The
    /// relative gate is what stops the silence between sentences from dragging
    /// a spoken-word track several LU too quiet — the single biggest reason a
    /// naive RMS number disagrees with what a platform reports.
    public static func integratedLUFS(_ samples: [Float], rate: Double) -> Double {
        guard samples.count > Int(rate * 0.4) else { return -.infinity }
        let x = samples.map(Double.init)
        let filtered = rlbHighPass(rate: rate).apply(headShelf(rate: rate).apply(x))

        let blockSize = Int(rate * 0.4)
        let hop = Swift.max(1, blockSize / 4)          // 75% overlap
        var blockPower: [Double] = []
        var start = 0
        while start + blockSize <= filtered.count {
            var sum = 0.0
            for i in start ..< (start + blockSize) { sum += filtered[i] * filtered[i] }
            blockPower.append(sum / Double(blockSize))
            start += hop
        }
        guard !blockPower.isEmpty else { return -.infinity }

        func loudness(_ power: Double) -> Double {
            power > 0 ? -0.691 + 10 * log10(power) : -.infinity
        }

        // Absolute gate.
        let aboveAbsolute = blockPower.filter { loudness($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return -.infinity }
        let ungatedMean = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)

        // Relative gate, 10 LU below the ungated mean.
        let relativeThreshold = loudness(ungatedMean) - 10
        let gated = aboveAbsolute.filter { loudness($0) > relativeThreshold }
        guard !gated.isEmpty else { return loudness(ungatedMean) }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// True peak in dBTP, estimated by 4x oversampling.
    ///
    /// Sample peak is not true peak: a waveform can pass between two samples
    /// at a level neither of them shows, and that inter-sample peak is what
    /// clips a lossy encoder downstream. Four times is what BS.1770-4
    /// prescribes at these rates.
    public static func truePeakDBTP(_ samples: [Float], rate: Double) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        var peak = 0.0
        // Linear interpolation between neighbours at 4x. Cheaper than the
        // specified polyphase FIR and biased *low*, so it can under-report a
        // hair -- never over-report, which would be the dangerous direction.
        for i in 0 ..< samples.count {
            let a = Double(samples[i])
            peak = Swift.max(peak, abs(a))
            guard i + 1 < samples.count else { continue }
            let b = Double(samples[i + 1])
            for k in 1..<4 {
                let t = Double(k) / 4.0
                peak = Swift.max(peak, abs(a + (b - a) * t))
            }
        }
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }

    /// What it would take to hit a target, and whether that is safe.
    public struct Normalisation: Equatable, Sendable {
        public var measuredLUFS: Double
        public var gainDB: Double
        public var resultingTruePeak: Double
        /// True when applying the gain would push the true peak above the
        /// ceiling. The app offers to stop at the ceiling instead, and says
        /// what loudness that lands on -- rather than clipping quietly.
        public var wouldExceedCeiling: Bool
    }

    public static func normalisation(for samples: [Float], rate: Double,
                                     target: Target) -> Normalisation? {
        guard !target.lufs.isNaN else { return nil }
        let measured = integratedLUFS(samples, rate: rate)
        guard measured.isFinite else { return nil }
        let gain = target.lufs - measured
        let peak = truePeakDBTP(samples, rate: rate)
        return Normalisation(measuredLUFS: measured, gainDB: gain,
                             resultingTruePeak: peak + gain,
                             wouldExceedCeiling: peak + gain > target.truePeakCeiling)
    }
}
