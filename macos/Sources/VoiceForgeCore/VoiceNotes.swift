import Foundation

/// What is known about each bundled voice, and — as important — which voice it
/// was learned from.
///
/// This exists because a claim got attached to the wrong thing. The pace dial
/// said *"the reader's own rate, measured to within 0.3%"* under every voice.
/// That measurement is real, but it was made on **snepssen-rode** by comparing
/// 60 rendered lines against the reader's own recordings of the same text.
/// The voice this app now ships as `snepssen` was fine-tuned on generated
/// audio rather than on the reader, and on identical copy it reads **31%
/// faster** — 194 words a minute against 148, with commas worth 145 ms
/// against 457. Printing rode's measurement under it was simply false.
///
/// So notes are per voice, and a voice with no measurement says so rather than
/// borrowing one.
public struct VoiceNote: Equatable, Sendable {
    public var name: String
    /// One line for the picker.
    public var summary: String
    /// What `lengthScale` 1.0 means for *this* voice, or nil when nobody has
    /// measured it against a reference.
    public var paceReference: String?
    /// Words a minute on ordinary prose, measured. Nil when unmeasured.
    public var typicalWPM: Double?

    public init(name: String, summary: String, paceReference: String?, typicalWPM: Double?) {
        self.name = name; self.summary = summary
        self.paceReference = paceReference; self.typicalWPM = typicalWPM
    }
}

public enum VoiceNotes {
    /// Only voices this project has actually measured. A voice somebody
    /// installs is not in here and must not borrow anybody's numbers.
    public static let all: [VoiceNote] = [
        .init(name: "snepssen",
              summary: "The voice this app ships with. Measured on ordinary prose: 194 words a minute, commas worth about 145 ms.",
              paceReference: nil,
              typicalWPM: 194),
        // Kept because it is a voice somebody may still have installed, and a
        // measurement already exists for it. Not bundled: Voice Forge ships one
        // voice, and this one lives on in Gateway Forge where it was measured.
        .init(name: "snepssen-rode",
              summary: "Fine-tuned on the reader's own microphone recordings. Slower and closer to life: 148 words a minute, commas worth about 457 ms.",
              paceReference: "The reader's own rate, measured to within 0.3% against their own recordings. A departure from here is a choice, not a correction.",
              typicalWPM: 148),
    ]

    public static func note(_ name: String) -> VoiceNote? {
        all.first { $0.name == name }
    }

    /// What to print under the pace dial for a given voice and value.
    public static func paceNote(voice: String, lengthScale v: Double) -> String {
        let atOne = abs(v - 1.0) < 0.005
        let reference = note(voice)?.paceReference
        if atOne {
            return reference
                ?? "This voice's own rate — where it was trained, not a likeness anybody has measured against a reference recording."
        }
        let percent = Int(((v - 1.0) * 100).rounded())
        let base = percent > 0 ? "\(percent)% slower" : "\(-percent)% faster"
        if let wpm = note(voice)?.typicalWPM {
            return "\(base) than this voice's own \(Int(wpm)) words a minute — about \(Int((wpm / v).rounded()))."
        }
        // An installed voice nobody here has measured. Say the ratio and
        // nothing else; borrowing another voice's rate would be a guess
        // dressed as a measurement.
        return "\(base) than this voice's own rate, whatever that is — this voice has not been measured here."
    }
}
