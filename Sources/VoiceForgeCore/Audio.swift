import Foundation

/// Mono float samples and the arithmetic over them.
///
/// The model speaks at 22.05 kHz and that is the number this app works in.
/// Gateway Forge resampled to 24 kHz on the way out of the engine so that
/// nothing downstream of it had to change; here there is no downstream to
/// protect, and resampling twice — once to a working rate, once to the export
/// rate — is two chances to lose something for no gain. Export resamples once,
/// from the model's own rate to whatever the video wants.
public enum Audio {
    /// What the bundled voices actually generate. Read from the voice config
    /// at load time rather than trusted from here; this is the expected value,
    /// and `vfrender` reports a mismatch instead of silently resampling.
    public static let modelSampleRate: Double = 22_050

    /// Sample rates worth offering on export. 48 kHz is what video wants;
    /// 44.1 is what music wants; 22.05 is the model's own, which is the only
    /// one that involves no resampling at all.
    public static let exportRates: [Double] = [22_050, 44_100, 48_000]

    public static func silence(seconds: Double, at rate: Double) -> [Float] {
        guard seconds > 0 else { return [] }
        return [Float](repeating: 0, count: Int((seconds * rate).rounded()))
    }

    public static func seconds(_ samples: [Float], at rate: Double) -> Double {
        rate > 0 ? Double(samples.count) / rate : 0
    }

    /// Peak sample magnitude, linear.
    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { Swift.max($0, abs($1)) }
    }

    /// Peak in dBFS. Silence reports -.infinity rather than a made-up floor,
    /// so a caller has to decide what to show for it.
    public static func peakDBFS(_ samples: [Float]) -> Double {
        let p = Double(peak(samples))
        return p > 0 ? 20 * log10(p) : -.infinity
    }

    public static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// Apply a linear gain, reporting whether anything clipped. The caller is
    /// told rather than silently limited: a normaliser that quietly squashes
    /// peaks is how a voiceover arrives distorted with nothing in the log.
    public static func applyGain(_ samples: [Float], _ gain: Double) -> (samples: [Float], clipped: Int) {
        var clipped = 0
        let out = samples.map { s -> Float in
            let v = Double(s) * gain
            if v > 1 || v < -1 { clipped += 1 }
            return Float(Swift.max(-1, Swift.min(1, v)))
        }
        return (out, clipped)
    }

    /// Linear ramp in and out, to make an independently decoded edge safe.
    public static func fadeEdges(_ samples: inout [Float], seconds: Double, at rate: Double) {
        let n = Swift.min(samples.count / 2, Int(seconds * rate))
        guard n > 1 else { return }
        let denominator = Float(n - 1)
        for i in 0..<n {
            let gain = Float(i) / denominator
            samples[i] *= gain
            samples[samples.count - 1 - i] *= gain
        }
    }

    /// How much of the head and tail is below an audible floor.
    ///
    /// Used to measure what the model actually produced rather than what it
    /// was asked for: the gap a comma opens is the silence the model put
    /// there, and it can only be found by looking.
    public static func quietHead(_ samples: [Float], threshold: Float = 0.002) -> Int {
        var n = 0
        while n < samples.count, abs(samples[n]) < threshold { n += 1 }
        return n
    }

    public static func quietTail(_ samples: [Float], threshold: Float = 0.002) -> Int {
        var n = 0
        while n < samples.count, abs(samples[samples.count - 1 - n]) < threshold { n += 1 }
        return n
    }

    /// The longest run of near-silence inside a buffer, as (start, length) in
    /// samples. Nil when nothing crosses the threshold for long enough.
    ///
    /// This is how a clause pause is measured. The model does not report where
    /// it put a breath; the only honest way to say how long a comma is worth
    /// is to render with and without one and look at what changed.
    public static func longestQuietRun(_ samples: [Float], threshold: Float = 0.002,
                                       minimumLength: Int = 1) -> (start: Int, length: Int)? {
        var best: (start: Int, length: Int)?
        var runStart = 0
        var inRun = false
        for i in samples.indices {
            let quiet = abs(samples[i]) < threshold
            if quiet && !inRun { inRun = true; runStart = i }
            if !quiet && inRun {
                inRun = false
                let length = i - runStart
                if length >= minimumLength, length > (best?.length ?? 0) {
                    best = (runStart, length)
                }
            }
        }
        if inRun {
            let length = samples.count - runStart
            if length >= minimumLength, length > (best?.length ?? 0) { best = (runStart, length) }
        }
        return best
    }
}
