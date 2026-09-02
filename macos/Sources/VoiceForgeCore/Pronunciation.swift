import Foundation

/// A word, and how this voice should say it.
///
/// The override is IPA, because that is what the model actually consumes:
/// espeak hands it a string of IPA symbols and the voice knows 161 of them.
/// Writing IPA is therefore not a translation step — it *is* the thing, and
/// what you type is what the model is handed.
///
/// The alternative mechanism was tested and rejected. espeak-ng has its own
/// inline phoneme syntax, `[[snˈɛpsən]]`, which would have let espeak do the
/// splicing; through this project's call path it does not work at all. espeak
/// reads the brackets as literal text and pronounces the IPA *by name* —
/// `[[snˈɛpsən]]` came back as `ˈɛs ˈɛn stɹˈɛs ˌoʊpənˈɛː pˈiːʲ ˈɛs ʃwˈɑː ˈɛn`,
/// which is "S N stress open-E P E S schwa N" spoken aloud. So the substitution
/// is done here instead: phonemize the word on its own to learn what espeak
/// would say, then replace exactly that in the sentence.
public struct PronunciationEntry: Codable, Equatable, Identifiable, Sendable {

    /// Where an entry applies.
    public enum Scope: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Every script, for good. Your own name, a brand you always say,
        /// a term of art you use in every video.
        case global
        /// This script only. One video's cast list, a place name in this
        /// piece and nowhere else.
        case project

        public var id: String { rawValue }
        public var label: String { self == .global ? "Everywhere" : "This script" }
        public var note: String {
            self == .global
                ? "Kept across every script you write."
                : "Kept with this script only, and overrides a global entry for the same word."
        }
    }

    public var id: UUID
    /// The word as written, matched without regard to case.
    public var word: String
    /// The IPA to say instead.
    public var ipa: String
    public var scope: Scope
    public var enabled: Bool

    public init(id: UUID = UUID(), word: String, ipa: String,
                scope: Scope = .global, enabled: Bool = true) {
        self.id = id; self.word = word; self.ipa = ipa
        self.scope = scope; self.enabled = enabled
    }

    public var key: String { word.lowercased() }
}

/// What is wrong with an entry, if anything.
///
/// **Validation is not politeness here, it is the whole safety mechanism.**
/// The phoneme mapper skips a symbol it does not recognise — `guard let id =
/// map[key] else { continue }` — so an unknown character does not fail, it
/// silently disappears and the word comes out with a hole in it. Typing an
/// ASCII `r` where IPA wants `ɹ`, or a `ʁ` this voice never learned, costs you
/// a sound and says nothing. So every character is checked against the voice's
/// own vocabulary before an entry is allowed to do anything.
public struct PronunciationProblem: Equatable, Sendable {

    /// Characters the voice has no phoneme for. **Silently discarded** by the
    /// phoneme mapper — `guard let id = map[key] else { continue }` — so the
    /// sound is simply lost with no error anywhere.
    ///
    /// Measured against the real vocabulary rather than imagined: the things
    /// that actually vanish are the `/slashes/` a dictionary entry is normally
    /// quoted between, `[brackets]`, capital letters, and accented Latin. An
    /// ASCII `r` does *not* vanish — it is the IPA alveolar trill and the model
    /// knows it — which is a different and sneakier problem, handled below.
    public var unknownSymbols: [String]

    /// Punctuation the model knows *as punctuation*. Worse than dropping: `.`
    /// is the full-stop phoneme, so a syllable dot inside a word does not get
    /// ignored, it inserts a sentence boundary in the middle of the word.
    public var punctuationSymbols: [String]

    /// Characters that are valid IPA, present in the vocabulary, and almost
    /// certainly not what was meant. Both of these are real IPA letters, so
    /// nothing is lost and nothing warns — the word just comes out wrong.
    ///
    ///  · ASCII `r` (U+0072) is the *trilled* r of Spanish, not English `ɹ`.
    ///  · ASCII `g` (U+0067) and IPA `ɡ` (U+0261) look identical in most fonts
    ///    and are different phonemes to this model.
    public var lookalikes: [(typed: String, meant: String, name: String)]

    public var isEmpty: Bool

    /// Blocking problems lose or break sounds. Look-alikes only warn: they are
    /// legitimate IPA and somebody may mean them.
    public var isBlocking: Bool {
        !unknownSymbols.isEmpty || !punctuationSymbols.isEmpty || isEmpty
    }
    public var hasWarning: Bool { !lookalikes.isEmpty }

    public static func == (a: PronunciationProblem, b: PronunciationProblem) -> Bool {
        a.unknownSymbols == b.unknownSymbols
            && a.punctuationSymbols == b.punctuationSymbols
            && a.isEmpty == b.isEmpty
            && a.lookalikes.map(\.typed) == b.lookalikes.map(\.typed)
    }

    static func named(_ s: String) -> String {
        let code = s.unicodeScalars.first.map { String(format: "U+%04X", $0.value) } ?? "?"
        return "\(s) (\(code))"
    }

    public var message: String {
        if isEmpty { return "Nothing to say." }
        var parts: [String] = []
        if !unknownSymbols.isEmpty {
            let list = unknownSymbols.map(Self.named).joined(separator: " ")
            parts.append("This voice has no \(list) — it would be dropped and the sound lost."
                + (unknownSymbols.contains("/") || unknownSymbols.contains("[")
                   ? " Write the symbols on their own, without the brackets a dictionary quotes them in." : ""))
        }
        if !punctuationSymbols.isEmpty {
            let list = punctuationSymbols.map(Self.named).joined(separator: " ")
            parts.append("\(list) is punctuation to this model, not a sound — inside a word it would break the sentence in half.")
        }
        for l in lookalikes {
            parts.append("\(Self.named(l.typed)) is \(l.name). For English you almost certainly want \(Self.named(l.meant)).")
        }
        return parts.joined(separator: " ")
    }
}

public struct PronunciationDictionary: Equatable, Sendable {
    public var entries: [PronunciationEntry]

    public init(entries: [PronunciationEntry] = []) { self.entries = entries }

    public var global: [PronunciationEntry] { entries.filter { $0.scope == .global } }
    public var project: [PronunciationEntry] { entries.filter { $0.scope == .project } }

    /// The entries actually in force, one per word.
    ///
    /// A project entry beats a global one for the same word — that is what
    /// "override" means, and it is resolved here rather than at the point of
    /// use so there is one answer to "what will this say".
    public var effective: [PronunciationEntry] {
        var byWord: [String: PronunciationEntry] = [:]
        for e in entries where e.enabled && !e.ipa.isEmpty {
            if let existing = byWord[e.key], existing.scope == .project, e.scope == .global {
                continue                       // the project entry already won
            }
            byWord[e.key] = e
        }
        return byWord.values.sorted { $0.word.lowercased() < $1.word.lowercased() }
    }

    /// True when a global entry for this word is being shadowed by a project
    /// one. Worth showing: an entry that does nothing should look like it.
    public func isShadowed(_ entry: PronunciationEntry) -> Bool {
        guard entry.scope == .global, entry.enabled else { return false }
        return entries.contains { $0.key == entry.key && $0.scope == .project && $0.enabled }
    }

    /// Check an IPA string against a voice's vocabulary.
    ///
    /// - Parameter vocabulary: every symbol the model knows. Passed in rather
    ///   than known here, because this target must not load a model — and
    ///   because the two bundled voices could in principle differ.
    /// Punctuation the model carries as phonemes. Legal symbols, but they end
    /// clauses and sentences rather than making a sound.
    static let punctuation: Set<String> = [".", ",", ";", ":", "?", "!", "(", ")", "\"", "-"]

    static let lookalikes: [(typed: String, meant: String, name: String)] = [
        ("r", "\u{0279}", "the trilled r of Spanish or Italian"),
        ("g", "\u{0261}", "a different letter from the IPA g, though most fonts draw them alike"),
    ]

    public static func problem(with ipa: String, vocabulary: Set<String>) -> PronunciationProblem {
        let trimmed = ipa.trimmingCharacters(in: .whitespaces)
        var unknown: [String] = []
        var punct: [String] = []
        var confused: [(typed: String, meant: String, name: String)] = []
        for scalar in trimmed.unicodeScalars {
            let s = String(scalar)
            if s == " " { continue }
            if !vocabulary.contains(s) {
                if !unknown.contains(s) { unknown.append(s) }
            } else if punctuation.contains(s) {
                if !punct.contains(s) { punct.append(s) }
            } else if let l = lookalikes.first(where: { $0.typed == s }),
                      !confused.contains(where: { $0.typed == s }) {
                confused.append(l)
            }
        }
        return PronunciationProblem(unknownSymbols: unknown, punctuationSymbols: punct,
                                    lookalikes: confused, isEmpty: trimmed.isEmpty)
    }

    /// Apply the dictionary to one sentence's phonemes.
    ///
    /// Matching is on whole space-separated groups, not plain substring: espeak
    /// separates words with spaces in its IPA output, and a bare
    /// `replacingOccurrences` would happily rewrite the middle of a longer
    /// word. `kˈʌbɹɪk` must not match inside some other word that happens to
    /// contain those symbols.
    ///
    /// - Parameter defaults: what espeak says for each word on its own, keyed
    ///   by the entry's `key`. The caller supplies these because producing them
    ///   needs the phonemizer.
    /// - Returns: the rewritten phonemes, and which entries actually landed.
    public static func apply(_ entries: [PronunciationEntry], to phonemes: String,
                             defaults: [String: String]) -> (phonemes: String, applied: Set<String>) {
        var groups = phonemes.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var applied: Set<String> = []

        for entry in entries {
            guard let fallback = defaults[entry.key], !fallback.isEmpty else { continue }
            let want = fallback.split(separator: " ").map(String.init)
            guard !want.isEmpty else { continue }

            var i = 0
            while i + want.count <= groups.count {
                // A group may carry trailing punctuation the phonemizer added
                // (`kˈʌbɹɪk.`), so compare on the phoneme part and keep the tail.
                let window = Array(groups[i ..< (i + want.count)])
                let (matches, tail) = Self.matches(window, want)
                if matches {
                    groups.replaceSubrange(i ..< (i + want.count), with: [entry.ipa + tail])
                    applied.insert(entry.key)
                    i += 1
                } else {
                    i += 1
                }
            }
        }
        return (groups.joined(separator: " "), applied)
    }

    /// Whether a window of phoneme groups is the word we are looking for,
    /// allowing the last group to carry punctuation.
    static func matches(_ window: [String], _ want: [String]) -> (Bool, String) {
        guard window.count == want.count, !window.isEmpty else { return (false, "") }
        for i in 0 ..< (window.count - 1) where window[i] != want[i] { return (false, "") }
        let last = window[window.count - 1]
        let wantLast = want[want.count - 1]
        guard last.hasPrefix(wantLast) else { return (false, "") }
        let tail = String(last.dropFirst(wantLast.count))
        // Only punctuation may trail. Anything else means this is a longer
        // word that merely starts the same way.
        guard tail.allSatisfy({ !$0.isLetter && !Self.isPhonemeSymbol($0) }) else { return (false, "") }
        return (true, tail)
    }

    /// Rough test for "this is a phoneme rather than punctuation". Used only to
    /// refuse a partial match, so it errs toward refusing.
    static func isPhonemeSymbol(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        // Latin letters, IPA extensions, spacing modifiers, combining marks.
        return (s.value >= 0x0250 && s.value <= 0x02FF)
            || (s.value >= 0x0300 && s.value <= 0x036F)
            || (s.value >= 0x1D00 && s.value <= 0x1D7F)
            || c.isLetter
    }
}
