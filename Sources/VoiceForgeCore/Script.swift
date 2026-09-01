import Foundation

/// A script, cut the way the model wants to be fed.
///
/// **One inference call per sentence, never less, never more.** That is not a
/// preference — it is what this engine was measured into. Flattening several
/// sentences into one call produces a shape the model never saw in training
/// (Piper phonemizes and synthesises a sentence at a time, and so did its
/// fine-tuning), and it was heard as a phantom "-eth" on the tail of the last
/// sentence in eight draws out of eight. Cutting *inside* a sentence is the
/// opposite error and costs a stutter at the seam, because each call starts
/// cold with no audio context: that one was heard as "y-you".
///
/// So a sentence is the unit. Everything this app offers in the way of pause
/// control is built either between sentences, where there is a real boundary
/// to lengthen, or inside a single call, by giving the model more room to
/// breathe — never by cutting a sentence into pieces.
public struct Script: Equatable, Sendable {

    /// One sentence: the smallest thing that gets its own inference call.
    public struct Sentence: Equatable, Sendable, Identifiable {
        public var id: Int
        public var text: String
        /// Which paragraph it belongs to. A paragraph break is a longer pause
        /// than a full stop and the listener can set them separately.
        public var paragraph: Int
        /// True when this is the last sentence of its paragraph.
        public var endsParagraph: Bool
        /// The punctuation this sentence ends on, or "" when it just stops.
        public var terminator: String
        /// How many clause breaks (`,` `;` `:` and the em dash) it contains.
        /// Read-only, but it is what tells the listener why one sentence
        /// carries more pause budget than another.
        public var clauseBreaks: Int

        public init(id: Int, text: String, paragraph: Int, endsParagraph: Bool,
                    terminator: String, clauseBreaks: Int) {
            self.id = id; self.text = text; self.paragraph = paragraph
            self.endsParagraph = endsParagraph; self.terminator = terminator
            self.clauseBreaks = clauseBreaks
        }
    }

    public var sentences: [Sentence]

    public var isEmpty: Bool { sentences.isEmpty }
    public var paragraphCount: Int { (sentences.map(\.paragraph).max() ?? -1) + 1 }
    public var wordCount: Int {
        sentences.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// The marks this app treats as a clause break inside a sentence.
    ///
    /// espeak-ng's own clause terminators, matched to what `EspeakPhonemizer`
    /// already reports: comma, semicolon and colon. The em dash is included
    /// because writing for voiceover uses it as a breath and espeak gives it
    /// one; the hyphen is not, because it joins rather than separates.
    public static let clauseMarks: Set<Character> = [",", ";", ":", "—"]

    /// Cut a script into paragraphs and sentences.
    ///
    /// A blank line starts a paragraph. Sentence ends are `.`, `!` and `?`
    /// followed by whitespace or the end of the text — a full stop between
    /// digits is a decimal point and does not end anything, which is the one
    /// case that bites in written-for-speech copy ("$4.99", "1.5x").
    public static func parse(_ text: String) -> Script {
        var out: [Sentence] = []
        var id = 0
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for (p, paragraph) in paragraphs.enumerated() {
            let pieces = splitSentences(paragraph)
            for (i, piece) in pieces.enumerated() {
                let terminator = piece.last.map { ".!?".contains($0) ? String($0) : "" } ?? ""
                out.append(Sentence(id: id, text: piece, paragraph: p,
                                    endsParagraph: i == pieces.count - 1,
                                    terminator: terminator,
                                    clauseBreaks: piece.filter { clauseMarks.contains($0) }.count))
                id += 1
            }
        }
        return Script(sentences: out)
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard ch == "." || ch == "!" || ch == "?" else { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            // A full stop between digits is a decimal point.
            if ch == ".", next.isNumber { continue }
            if next == " " || next == "\n" || i + 1 == chars.count {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    public init(sentences: [Sentence]) { self.sentences = sentences }
}
