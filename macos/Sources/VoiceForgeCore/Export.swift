import AVFoundation
import Foundation

/// Writing the result out, at the rate and depth the destination wants.
///
/// AVFoundation is imported here rather than in the engine target because
/// `vfcheck` links this and must be able to exercise export end to end. It is
/// a system framework, so that costs the harness nothing — unlike the ONNX
/// stack, which is the thing the harness is kept away from.
public enum Export {

    public enum Depth: String, CaseIterable, Sendable, Codable, Identifiable {
        case pcm16 = "16-bit"
        case pcm24 = "24-bit"
        public var id: String { rawValue }
        public var bits: Int { self == .pcm16 ? 16 : 24 }
        public var note: String {
            self == .pcm16
                ? "What a video editor expects. Fine for a finished voiceover."
                : "More headroom for further editing. Twice the file size for the same length."
        }
    }

    public struct Settings: Equatable, Sendable, Codable {
        public var sampleRate: Double = 48_000
        public var depth: Depth = .pcm16
        /// Nil means leave the level alone.
        public var targetLUFS: Double? = -14
        public var truePeakCeiling: Double = -1
        public init() {}
    }

    public enum ExportError: LocalizedError {
        case resamplerUnavailable
        case bufferAllocationFailed
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .resamplerUnavailable: "Could not create a resampler for that rate."
            case .bufferAllocationFailed: "Could not allocate an audio buffer."
            case .writeFailed(let why): "Could not write the file: \(why)"
            }
        }
    }

    /// What the export actually did, so the app reports rather than promises.
    public struct Receipt: Equatable, Sendable {
        public var url: URL
        public var seconds: Double
        public var sampleRate: Double
        public var depth: Depth
        public var lufsBefore: Double
        public var lufsAfter: Double
        public var truePeakAfter: Double
        public var gainApplied: Double
        public var clippedSamples: Int
        /// True when the gain needed for the target was held back to keep the
        /// true peak under the ceiling. The listener is told, because the file
        /// is then quieter than the target they picked and that is not a bug.
        public var heldBackByCeiling: Bool
    }

    /// What an export *would* do, without writing anything.
    ///
    /// The reason this exists: a single voice reading a script is typically
    /// around -24 LUFS with peaks near -6 dBFS, and reaching a -14 target from
    /// there needs about +10 dB of gain that the true-peak ceiling will not
    /// allow. The export then lands several LU short. That is correct behaviour
    /// — holding at the ceiling beats clipping — but discovering it *after*
    /// writing the file is the wrong order. The numbers are all knowable in
    /// advance, so they are shown in advance.
    public struct Preview: Equatable, Sendable {
        public var lufs: Double
        public var truePeak: Double
        public var gainWanted: Double
        public var gainPossible: Double
        public var resultingLUFS: Double
        public var heldBack: Bool
        /// How far short of the target the ceiling forces it. Zero when the
        /// target is reachable or there is no target.
        public var shortfall: Double { Swift.max(0, gainWanted - gainPossible) }
    }

    public static func preview(_ samples: [Float], at sourceRate: Double,
                               settings: Settings) -> Preview? {
        guard let audio = try? resample(samples, from: sourceRate, to: settings.sampleRate)
        else { return nil }
        let lufs = Loudness.integratedLUFS(audio, rate: settings.sampleRate)
        let peak = Loudness.truePeakDBTP(audio, rate: settings.sampleRate)
        guard lufs.isFinite else { return nil }
        guard let target = settings.targetLUFS else {
            return Preview(lufs: lufs, truePeak: peak, gainWanted: 0, gainPossible: 0,
                           resultingLUFS: lufs, heldBack: false)
        }
        let wanted = target - lufs
        let possible = Swift.min(wanted, settings.truePeakCeiling - peak)
        return Preview(lufs: lufs, truePeak: peak, gainWanted: wanted,
                       gainPossible: possible, resultingLUFS: lufs + possible,
                       heldBack: possible < wanted - 0.01)
    }

    public static func resample(_ samples: [Float], from: Double, to: Double) throws -> [Float] {
        guard from != to else { return samples }
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from,
                                        channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt)
        else { throw ExportError.resamplerUnavailable }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                           frameCapacity: AVAudioFrameCount(max(1, samples.count)))
        else { throw ExportError.bufferAllocationFailed }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            inBuf.floatChannelData![0].update(from: base, count: samples.count)
        }
        let outFrames = AVAudioFrameCount(Double(samples.count) * to / from + 4096)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outFrames)
        else { throw ExportError.bufferAllocationFailed }

        var fed = false
        var convErr: NSError?
        converter.convert(to: outBuf, error: &convErr) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if let convErr { throw convErr }
        guard let ch = outBuf.floatChannelData else { throw ExportError.bufferAllocationFailed }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }

    /// Resample, normalise if asked, write a WAV, and report what happened.
    ///
    /// Order matters and is not arbitrary: **resample first, then measure, then
    /// gain.** Loudness and true peak both change with sample rate — a resample
    /// creates inter-sample peaks that were not there before — so measuring at
    /// the model's rate and applying the answer to a 48 kHz file would report a
    /// number the file does not have.
    @discardableResult
    public static func write(_ samples: [Float], at sourceRate: Double,
                             to url: URL, settings: Settings) throws -> Receipt {
        var audio = try resample(samples, from: sourceRate, to: settings.sampleRate)
        let before = Loudness.integratedLUFS(audio, rate: settings.sampleRate)

        var gainDB = 0.0
        var heldBack = false
        if let target = settings.targetLUFS, before.isFinite {
            gainDB = target - before
            let peak = Loudness.truePeakDBTP(audio, rate: settings.sampleRate)
            if peak + gainDB > settings.truePeakCeiling {
                gainDB = settings.truePeakCeiling - peak
                heldBack = true
            }
        }
        var clipped = 0
        if gainDB != 0 {
            let applied = Audio.applyGain(audio, pow(10, gainDB / 20))
            audio = applied.samples
            clipped = applied.clipped
        }

        try writeWAV(audio, rate: settings.sampleRate, depth: settings.depth, to: url)
        return Receipt(url: url,
                       seconds: Audio.seconds(audio, at: settings.sampleRate),
                       sampleRate: settings.sampleRate, depth: settings.depth,
                       lufsBefore: before,
                       lufsAfter: Loudness.integratedLUFS(audio, rate: settings.sampleRate),
                       truePeakAfter: Loudness.truePeakDBTP(audio, rate: settings.sampleRate),
                       gainApplied: gainDB, clippedSamples: clipped,
                       heldBackByCeiling: heldBack)
    }

    /// A plain RIFF/WAVE writer. Hand-rolled because AVAudioFile will not write
    /// 24-bit packed PCM, which is the one depth a further-editing workflow
    /// actually wants.
    public static func writeWAV(_ samples: [Float], rate: Double, depth: Depth,
                                to url: URL) throws {
        let bytesPerSample = depth.bits / 8
        let dataBytes = samples.count * bytesPerSample
        var out = Data(capacity: 44 + dataBytes)

        func append(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataBytes))
        append("WAVE")
        append("fmt ")
        append32(16)                                   // PCM chunk size
        append16(1)                                    // PCM
        append16(1)                                    // mono
        append32(UInt32(rate))
        append32(UInt32(rate) * UInt32(bytesPerSample)) // byte rate
        append16(UInt16(bytesPerSample))                // block align
        append16(UInt16(depth.bits))
        append("data")
        append32(UInt32(dataBytes))

        for s in samples {
            let clamped = Swift.max(-1, Swift.min(1, Double(s)))
            switch depth {
            case .pcm16:
                // Asymmetric, deliberately: full scale negative is -32768 and
                // full scale positive is 32767, so scaling both by 32767
                // is the conversion that cannot wrap.
                append16(UInt16(bitPattern: Int16((clamped * 32767).rounded())))
            case .pcm24:
                let v = Int32((clamped * 8_388_607).rounded())
                out.append(UInt8(truncatingIfNeeded: v))
                out.append(UInt8(truncatingIfNeeded: v >> 8))
                out.append(UInt8(truncatingIfNeeded: v >> 16))
            }
        }
        do { try out.write(to: url, options: .atomic) }
        catch { throw ExportError.writeFailed(error.localizedDescription) }
    }
}
