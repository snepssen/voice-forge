import Foundation

/// Deciding the dynamics instead of asking for them.
///
/// The per-sound layer can hold any sound by any amount, but nobody wants to
/// direct a paragraph one phoneme at a time. This derives a performance from
/// the text, so the manual controls become a way to disagree with a reading
/// rather than the only way to get one.
///
/// It leans on work espeak has already done. A phonemized sentence is not a
/// string of dictionary pronunciations: espeak has already reduced the function
/// words, demoted stress in context and run clitics together, so `I` arrives as
/// `aɪ` rather than `ˈaɪ` and `on the` arrives as one group, `ɔnðə`. That means
/// the stream itself says which words carry weight — a group with a primary
/// stress mark is one the language wants heard, and a group with none has
/// already been told to get out of the way. No word list, and no mapping back
/// to written words, which is just as well: written words do not survive the
/// journey one for one.
///
/// What espeak does not know is which word is the *point* of the sentence, and
/// Piper then renders whatever is left at an even distance. Three rules, no
/// model: put the accent where the phrase is heading, let a phrase end settle,
/// and stop hitting a word that has already been heard.
public struct ProsodySettings: Equatable, Sendable {
    /// How firmly the point of each phrase is made. Zero renders flat.
    public var focus: Double
    /// How much a phrase settles before its boundary.
    public var phraseFinal: Double
    /// How far a word already heard in this paragraph steps back.
    public var deaccentRepeats: Double
    /// How much unstressed material gives way, to keep the beats uneven.
    public var contrast: Double
    /// Extra hold on every accented nucleus, past what focus alone gives.
    public var nucleusHold: Double
    /// What a full accent is worth in level.
    public var accentDB: Double
    /// Where the line sits between flat and lifted, -1 to 1. The only control
    /// the model answers to with its own intonation rather than a filter.
    public var lift: Double

    public init(focus: Double = 0.7, phraseFinal: Double = 0.15,
                deaccentRepeats: Double = 0.6, contrast: Double = 0.12,
                nucleusHold: Double = 0, accentDB: Double = TimingPlan.fullAccentDB,
                lift: Double = 0) {
        self.focus = focus
        self.phraseFinal = phraseFinal
        self.deaccentRepeats = deaccentRepeats
        self.contrast = contrast
        self.nucleusHold = nucleusHold
        self.accentDB = accentDB
        self.lift = lift
    }
}

public enum Prominence: String, Sendable {
    case accented, secondary, reduced
}

public struct ProsodicGroup: Equatable, Sendable {
    /// Index of the group within the phoneme stream, which is what a direction
    /// addresses — not the index of a written word.
    public var word: Int
    public var phonemes: String
    public var prominence: Prominence
    /// Carries a clause mark, so the phrase turns over after it.
    public var endsPhrase: Bool
}

public enum Prosody {
    /// What each rule is worth at full strength.
    ///
    /// These are large because anything smaller does not exist. The graph rounds
    /// every token's duration up to a whole frame, and the median token on this
    /// voice is two frames — so a 5% direction moves 1 token in 123, and a 10%
    /// one moves 2. A direction has to reach roughly 20% before it is audible at
    /// all. The defaults are scaled down to compensate, which keeps the reading
    /// that was approved by ear exactly where it was.
    private static let focusHold = 0.3
    private static let phraseFinalHold = 1.15
    private static let contrastHold = 0.35

    private static let terminators: Set<Character> = [".", "?", "!"]

    /// Stress and punctuation removed, so "garden" and "garden," are one word
    /// again when asking whether it has already been said.
    public static func groupKey(_ phonemes: String) -> String {
        String(phonemes.filter {
            $0 != Phonology.primaryStress && $0 != Phonology.secondaryStress
                && !Script.clauseMarks.contains($0) && !terminators.contains($0)
        })
    }

    public static func prosodicGroups(_ layout: TokenLayout) -> [ProsodicGroup] {
        var groups: [ProsodicGroup] = []
        for word in 0 ..< max(0, layout.words) {
            let phonemes = TimingPlan.wordPhonemes(layout, word: word)
            guard !phonemes.isEmpty else { continue }
            let prominence: Prominence =
                phonemes.contains(Phonology.primaryStress) ? .accented
                : phonemes.contains(Phonology.secondaryStress) ? .secondary : .reduced
            groups.append(ProsodicGroup(
                word: word, phonemes: phonemes, prominence: prominence,
                endsPhrase: phonemes.contains {
                    Script.clauseMarks.contains($0) || terminators.contains($0)
                }))
        }
        return groups
    }

    /// A reading of one sentence, as directions the per-sound layer can render.
    ///
    /// `spoken` carries the words already heard earlier in the paragraph, so a
    /// repeat can step back the way a person's would. It is read, never written.
    public static func automaticDirections(_ layout: TokenLayout,
                                           settings: ProsodySettings = ProsodySettings(),
                                           spoken: Set<String> = []) -> [SoundDirection] {
        let groups = prosodicGroups(layout)
        guard !groups.isEmpty else { return [] }
        var directions: [Int: SoundDirection] = [:]

        // Unstressed material gives way a little. This is the whole thesis of
        // the app in one line: the beats are supposed to be uneven.
        if settings.contrast > 0 {
            for group in groups where group.prominence == .reduced {
                directions[group.word] = SoundDirection(
                    word: group.word,
                    stretch: 1 - contrastHold * clamp(settings.contrast))
            }
        }

        // Each phrase gets one point, made on the last word able to carry it.
        for phrase in phrases(groups) {
            let nucleus = phrase.last { $0.prominence == .accented }
                ?? phrase.last { $0.prominence == .secondary }
            if let nucleus {
                let repeated = spoken.contains(groupKey(nucleus.phonemes))
                let strength = clamp(settings.focus)
                    * (repeated ? 1 - clamp(settings.deaccentRepeats) : 1)
                directions[nucleus.word] = SoundDirection(
                    word: nucleus.word,
                    stretch: 1 + focusHold * strength,
                    accent: 0.6 * strength + max(0, settings.nucleusHold),
                    accentDB: max(0, settings.accentDB) * strength)
            }

            // A phrase settles at its edge whether or not the point was made there.
            if let last = phrase.last, settings.phraseFinal > 0, last.prominence != .reduced {
                let hold = 1 + phraseFinalHold * clamp(settings.phraseFinal)
                if var existing = directions[last.word] {
                    existing.stretch = max(existing.stretch, hold)
                    directions[last.word] = existing
                } else {
                    directions[last.word] = SoundDirection(word: last.word, stretch: hold)
                }
            }
        }

        // A direction that changes nothing is not a direction. Emitting one
        // would mark a word as directed in the interface and leave somebody
        // looking for the difference it made.
        return directions.values
            .filter { $0.stretch != 1 || $0.accent != 0 || $0.accentDB != 0 }
            .sorted { $0.word < $1.word }
    }

    /// Every word this sentence has now said, to carry into the next one.
    public static func spokenKeys(_ layout: TokenLayout) -> Set<String> {
        Set(prosodicGroups(layout).map { groupKey($0.phonemes) })
    }

    /// Split at clause marks, so each phrase can make its own point.
    private static func phrases(_ groups: [ProsodicGroup]) -> [[ProsodicGroup]] {
        var out: [[ProsodicGroup]] = []
        var current: [ProsodicGroup] = []
        for group in groups {
            current.append(group)
            if group.endsPhrase { out.append(current); current = [] }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}
