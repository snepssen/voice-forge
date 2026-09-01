import Foundation
import VoiceForgeCore
import VoiceForgeTTS

// The render primitive and the measurement rig. The only place outside the app
// where a model is loaded.
//
//   vfrender voices
//   vfrender say <voice> "text"  [out.wav]
//   vfrender calibrate <voice>

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("""
    vfrender voices                       list the bundled voices
    vfrender say <voice> "text" [out.wav] render one take
    vfrender calibrate <voice>            measure what each mark is worth
    """)
    exit(0)
}

switch command {
case "voices":
    let voices = VoiceEngine.bundledVoices()
    guard !voices.isEmpty else { fail("no bundled voices found") }
    for v in voices {
        let engine = try? VoiceEngine(voice: v)
        print("\(v)\(engine.map { "  \(Int($0.sampleRate)) Hz" } ?? "  UNLOADABLE")")
    }

case "say":
    guard args.count >= 3 else { fail("usage: vfrender say <voice> \"text\" [out.wav]") }
    let voice = args[1], text = args[2]
    let out = URL(fileURLWithPath: args.count > 3 ? args[3] : "take.wav")
    let engine = try VoiceEngine(voice: voice)
    let script = Script.parse(text)
    var settings = SynthesisSettings()
    // Honour a few overrides from the environment, so a measurement run can
    // sweep them without a rebuild.
    let env = ProcessInfo.processInfo.environment
    if let v = env["VF_LENGTH"].flatMap(Double.init) { settings.lengthScale = v }
    if let v = env["VF_NOISE"].flatMap(Double.init) { settings.noiseScale = v }
    if let v = env["VF_NOISEW"].flatMap(Double.init) { settings.noiseW = v }
    if let v = env["VF_CLAUSE_PADS"].flatMap(Int.init) { settings.clausePads = v }
    if let v = env["VF_SENTENCE_GAP"].flatMap(Double.init) { settings.sentenceGap = v }
    if let v = env["VF_PARAGRAPH_GAP"].flatMap(Double.init) { settings.paragraphGap = v }

    let started = Date()
    let rendered = try engine.render(script, settings: settings)
    let audio = engine.assemble(rendered)
    let elapsed = Date().timeIntervalSince(started)

    var export = Export.Settings()
    export.sampleRate = env["VF_RATE"].flatMap(Double.init) ?? 48_000
    export.targetLUFS = env["VF_LUFS"].flatMap(Double.init) ?? -14
    let receipt = try Export.write(audio, at: engine.sampleRate, to: out, settings: export)

    print("\(script.sentences.count) sentence(s), \(script.wordCount) words")
    for r in rendered {
        print(String(format: "  %.2fs  %5.1f wpm  peak %6.1f dBFS  +%.2fs gap  %@",
                     r.seconds, r.wordsPerMinute, r.peakDBFS, r.trailingGap,
                     r.text.prefix(52) + (r.text.count > 52 ? "…" : "")))
    }
    print(String(format: "%.2fs of audio in %.2fs (%.1fx realtime)",
                 receipt.seconds, elapsed, receipt.seconds / max(elapsed, 0.0001)))
    print(String(format: "%.1f LUFS -> %.1f LUFS (%+.1f dB), true peak %.1f dBTP%@",
                 receipt.lufsBefore, receipt.lufsAfter, receipt.gainApplied,
                 receipt.truePeakAfter,
                 receipt.heldBackByCeiling ? "  [held back by the ceiling]" : ""))
    if receipt.clippedSamples > 0 { print("CLIPPED: \(receipt.clippedSamples) samples") }
    print("wrote \(out.path)")

case "calibrate":
    guard args.count >= 2 else { fail("usage: vfrender calibrate <voice>") }
    let engine = try VoiceEngine(voice: args[1])
    var settings = SynthesisSettings()
    if let v = ProcessInfo.processInfo.environment["VF_LENGTH"].flatMap(Double.init) {
        settings.lengthScale = v
    }
    print("measuring \(args[1]) at length_scale \(settings.lengthScale)…")
    let cal = try engine.calibratePauses(settings: settings)
    print("")
    print("mark   mean      range              n")
    for m in cal.marks {
        print(String(format: "  %@    %5.0f ms  %5.0f – %-5.0f ms   %d",
                     m.mark.padding(toLength: 1, withPad: " ", startingAt: 0),
                     m.mean * 1000, m.minimum * 1000, m.maximum * 1000, m.samples))
    }
    print(String(format: "\none clause pad buys %.0f ms", cal.secondsPerClausePad * 1000))
    for pads in [0, 2, 4, 8] {
        print("  \(pads) pads: \(cal.clausePauseDescription(pads: pads))")
    }
    if let data = try? JSONEncoder().encode(cal),
       let s = String(data: data, encoding: .utf8) {
        let out = URL(fileURLWithPath: "calibration-\(args[1]).json")
        try? s.write(to: out, atomically: true, encoding: .utf8)
        print("\nwrote \(out.lastPathComponent)")
    }

case "probe":
    // Diagnostic: what does the signal actually look like at a comma?
    let engine = try VoiceEngine(voice: args[1])
    var settings = SynthesisSettings()
    if let v = ProcessInfo.processInfo.environment["VF_CLAUSE_PADS"].flatMap(Int.init) {
        settings.clausePads = v
    }
    let text = args.count > 2 ? args[2] : "The room was quiet, and nobody moved."
    let samples = try engine.renderSentence(text, settings: settings)
    let rate = engine.sampleRate
    print("\(text)  ->  \(samples.count) samples, \(String(format: "%.2f", Double(samples.count)/rate))s")
    print("peak \(String(format: "%.4f", Audio.peak(samples)))  rms \(String(format: "%.4f", Audio.rms(samples)))")
    for t in [Float(0.002), 0.005, 0.01, 0.02, 0.05] {
        let head = Audio.quietHead(samples, threshold: t)
        let tail = Audio.quietTail(samples, threshold: t)
        let interior = Array(samples[head..<(samples.count - tail)])
        let run = Audio.longestQuietRun(interior, threshold: t, minimumLength: Int(rate * 0.005))
        print(String(format: "  thr %.3f  head %5.0fms  tail %5.0fms  longest interior quiet %5.0fms",
                     Double(t), Double(head)/rate*1000, Double(tail)/rate*1000,
                     Double(run?.length ?? 0)/rate*1000))
    }
    // 20 ms RMS envelope, so the shape of the pause is visible.
    let win = Int(rate * 0.02)
    var env: [String] = []
    var i = 0
    while i + win <= samples.count {
        let r = Audio.rms(Array(samples[i..<(i+win)]))
        env.append(r < 0.002 ? "." : r < 0.01 ? ":" : r < 0.05 ? "o" : "O")
        i += win
    }
    print("  envelope (20ms/char): " + env.joined())

default: fail("unknown command \(command)")
}
