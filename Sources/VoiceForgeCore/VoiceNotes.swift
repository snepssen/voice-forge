import Foundation

/// What is known about each bundled voice, and — as important — which voice it
/// was learned from.
///
/// This exists because a claim got attached to the wrong thing. The pace dial
/// said *"the reader's own rate, measured to within 0.3%"* under every voice.
/// That measurement is real, but it was made on **snepssen-rode** by comparing
/// 60 rendered lines against the reader's own recordings of the same text.
/// snepssen-suno was fine-tuned on generated audio rather than on the reader,
/// and on identical copy it reads **31% faster** — 194 words a minute against
/// 148 — with commas worth 145 ms against 457. Printing rode's measurement
/// under suno was simply false.
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
    public static let all: [VoiceNote] = [
        .init(name: "snepssen-rode",
              summary: "Fine-tuned on the reader's own microphone recordings. The measured read: 148 words a minute, commas worth about 457 ms.",
              paceReference: "The reader's own rate, measured to within 0.3% against their own recordings. A departure from here is a choice, not a correction.",
              typicalWPM: 148),
        .init(name: "snepssen-suno",
              summary: "Fine-tuned on generated audio of the same speaker. Deeper, and noticeably quicker: 194 words a minute, commas worth about 145 ms.",
              paceReference: nil,
              typicalWPM: 194),
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
                ?? "This voice's own rate. Nobody has measured it against a reference recording, so 1.0 is where it was trained, not a known likeness."
        }
        let percent = Int(((v - 1.0) * 100).rounded())
        let base = percent > 0 ? "\(percent)% slower" : "\(-percent)% faster"
        if let wpm = note(voice)?.typicalWPM {
            return "\(base) than this voice's own \(Int(wpm)) words a minute — about \(Int((wpm / v).rounded()))."
        }
        return "\(base) than this voice's own rate."
    }
}
