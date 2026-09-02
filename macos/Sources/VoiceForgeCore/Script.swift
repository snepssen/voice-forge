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

    /// Words that end in a full stop without ending a sentence.
    ///
    /// Found by stress-testing rather than imagined. "Dr. Smith paid $4.99 on
    /// Jan. 3rd, i.e. last Tuesday" was being cut into four utterances — `Dr.`
    /// alone was a 0.63-second "sentence" — and each fragment then got its own
    /// inference call, its own sentence-final fall and its own gap. It did not
    /// crash; it just read like a broken machine.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "rev", "hon",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
        "vs", "etc", "approx", "est", "fig", "vol", "no", "ed", "eds", "pp", "ch",
        "inc", "ltd", "co", "corp", "dept", "univ", "min", "max", "avg",
        "ave", "blvd", "rd", "apt",
    ]

    /// Whether a terminator at `i` really ends a sentence.
    ///
    /// `!` and `?` always do. A full stop is the hard one, and three things
    /// stop it:
    ///
    ///  · **a decimal point** — `3.14`, `$4.99`, `3.5%`. Digits either side.
    ///  · **an abbreviation** — `Dr.`, `Jan.`, `etc.` A list, because there is
    ///    no rule; `Dr` is not a sentence and `Mr` is not either, and no amount
    ///    of cleverness derives that from the characters.
    ///  · **an initialism** — `U.S.`, `i.e.`, `a.m.` The letter before the stop
    ///    stands alone, which is what makes it a letter rather than a word.
    ///
    /// A "next word is lowercase, so this cannot be a sentence start" rule was
    /// tried first and **removed**. It fixed `U.K. disagree` for the wrong
    /// reason and broke informal writing in exchange: "ALL CAPS SHOUTING.
    /// mixed CaSe. hyphenated-words" merged into one utterance, and people
    /// write scripts in lowercase all the time. The two tests above do the same
    /// work without that cost.
    ///
    /// Where it is genuinely ambiguous — "I moved to the U.S. Then I left" —
    /// this joins rather than splits. The costs are not symmetric: joining two
    /// sentences gives one longer inference call, which the model handles;
    /// splitting one gives a false full stop, a falling intonation in the
    /// middle of a thought, and an inserted gap.
    static func endsSentence(_ chars: [Character], at i: Int) -> Bool {
        let ch = chars[i]
        guard ch == "." || ch == "!" || ch == "?" else { return false }

        // The next thing that is not a space, and whether a break followed.
        var j = i + 1
        while j < chars.count, chars[j] == " " { j += 1 }
        let sawSpace = j > i + 1 || j >= chars.count || chars[j] == "\n"
        let next: Character? = j < chars.count ? chars[j] : nil

        // A terminator must be followed by whitespace or the end of the text.
        guard sawSpace || next == nil else {
            // `3.14` and `example.com` — no space, so not a sentence end.
            return false
        }
        guard ch == "." else { return true }

        // The word immediately before the stop.
        var k = i - 1
        var word = ""
        while k >= 0, chars[k].isLetter { word.insert(chars[k], at: word.startIndex); k -= 1 }

        // An initialism: a lone letter whose own stop is right behind it.
        // `U.S.`, `i.e.`, `a.m.` The earlier stop in each of those never
        // splits either, because nothing follows it but a letter.
        if word.count == 1, k >= 0, chars[k] == "." { return false }

        if abbreviations.contains(word.lowercased()) { return false }
        return true
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard endsSentence(chars, at: i) else { continue }
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Give an em dash the spaces espeak needs in order to see it.
    ///
    /// **Measured, not assumed.** `quiet — and` phonemizes to `kwˈaɪət; ænd` —
    /// espeak turns a spaced em dash into a semicolon clause break, which is
    /// why `;` and `—` calibrate to the same number. `quiet—and` phonemizes to
    /// `kwˈaɪət ænd`, byte-identical to writing no dash at all. The mark is
    /// simply dropped.
    ///
    /// That mattered because the pause dial names `—` among the marks it gives
    /// room to. For `word—word`, which is how most people type an em dash, it
    /// was giving room to a break that did not exist. A control that names a
    /// mark has to make that mark work.
    ///
    /// This is whitespace around punctuation, not a respelling: no word is
    /// changed, and the dash does what it visibly means. A hyphen is left
    /// alone — it joins rather than separates, and espeak correctly runs
    /// `hyphenated-words` together as one phoneme run.
    public static func spacedEmDashes(_ text: String) -> String {
        guard text.contains("—") else { return text }
        var out = ""
        var pendingSpace = false
        for ch in text {
            if ch == "—" {
                if !out.hasSuffix(" ") { out += " " }
                out += "—"
                pendingSpace = true
            } else if pendingSpace {
                out += ch == " " ? " " : " \(ch)"
                pendingSpace = false
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Currency symbols and the words they are actually spoken as.
    ///
    /// espeak reads the symbol first and the number after it, the way it is
    /// written: `$4.99` becomes "dollar four point nine nine", and every
    /// currency behaves the same way — "pound four point nine nine", "euros
    /// four point nine nine", "yen four hundred". Nobody says that. English
    /// puts the amount first and the currency after it, and treats the part
    /// after the point as a second number rather than as decimals.
    ///
    /// Yen, won and lira do not take a plural s.
    public static let currencies: [(symbol: Character, singular: String, plural: String)] = [
        ("$", "dollar", "dollars"),
        ("£", "pound", "pounds"),
        ("€", "euro", "euros"),
        ("¥", "yen", "yen"),
        ("₩", "won", "won"),
        ("₺", "lira", "lira"),
        ("₽", "ruble", "rubles"),
        ("₹", "rupee", "rupees"),
        ("¢", "cent", "cents"),
    ]

    /// Rewrite written currency into the order it is spoken.
    ///
    ///     $4.99   ->  4 dollars 99          £4.50  ->  4 pounds 50
    ///     $1      ->  1 dollar              ¥400   ->  400 yen
    ///     $4.00   ->  4 dollars             $4.05  ->  4 dollars oh 5
    ///     $1,250  ->  1,250 dollars
    ///
    /// **This is the one place the app rewrites the listener's words, and it
    /// is switchable for exactly that reason.** Everything else here refuses
    /// to: the respelling table Gateway Forge carries was removed on the
    /// principle that a general tool must not quietly change what it was
    /// given. This earns its exception by being wrong otherwise in every case,
    /// in every currency, and by being visible and off-able rather than
    /// hidden.
    ///
    /// A symbol not followed by a digit is left alone, so `$` in a code sample
    /// or `€` used as a bare noun survives untouched.
    public static func spokenCurrency(_ text: String) -> String {
        guard text.contains(where: { c in currencies.contains { $0.symbol == c } }) else {
            return text
        }
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            guard let money = currencies.first(where: { $0.symbol == chars[i] }) else {
                out.append(chars[i]); i += 1; continue
            }
            // The amount: digits, with commas allowed inside.
            var j = i + 1
            var whole = ""
            while j < chars.count, chars[j].isNumber || (chars[j] == "," && j + 1 < chars.count && chars[j + 1].isNumber) {
                whole.append(chars[j]); j += 1
            }
            guard !whole.isEmpty else { out.append(chars[i]); i += 1; continue }

            // A point followed by digits is either a minor unit or part of the
            // number. Exactly two digits is cents; anything else is a decimal
            // and belongs to the amount.
            //
            // Getting this wrong is not cosmetic: leaving the tail in place
            // produced `$3.14159` -> "3 dollars.14159", which reads as "three
            // dollars point one four one five nine" -- the currency word
            // wedged into the middle of its own number.
            var minor: String?
            if j < chars.count, chars[j] == "." {
                var k = j + 1
                var digits = ""
                while k < chars.count, chars[k].isNumber { digits.append(chars[k]); k += 1 }
                if digits.count == 2 {
                    minor = digits; j = k
                } else if !digits.isEmpty {
                    whole += "." + digits; j = k
                }
            }

            let isOne = whole.replacingOccurrences(of: ",", with: "") == "1"
            out += whole + " " + (isOne ? money.singular : money.plural)
            if let minor, minor != "00" {
                // "oh five", not "zero five" -- it is how a price is read.
                out += minor.hasPrefix("0") ? " oh \(minor.dropFirst())" : " \(minor)"
            }
            i = j
        }
        return out
    }

    public init(sentences: [Sentence]) { self.sentences = sentences }
}
