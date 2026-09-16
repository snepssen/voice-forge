import Foundation

/// What each sound will and will not tolerate being held.
///
/// Stretching a whole word uniformly is what made "stole" read as "ssttoollee":
/// the ear hears a held /s/ and a smeared /t/ as a defect, and a held vowel as
/// delivery. So a request to slow a word down is not one number applied to its
/// tokens — it is one number weighted per sound, and a plosive's weight is zero.
///
/// The classes below describe the espeak IPA the bundled voice actually emits,
/// one Unicode scalar at a time, because that is the granularity the model's
/// phoneme id map is addressed at. Diphthongs arrive as two scalars and the
/// length mark as a third, which is a gift: it means the nucleus of a syllable
/// can be held without touching the consonants around it.
public enum PhonemeClass: String, CaseIterable, Sendable {
    case vowel
    case vowelExtension
    case sonorant
    case voicedFricative
    case voicelessFricative
    case plosive
    case marker
    case boundary

    /// How much of a requested stretch this class actually receives.
    ///
    /// Only the two ends of this scale are settled by listening: the vowel took
    /// a whole direction and was preferred, the word took a whole direction
    /// through its stops and was rejected. The values between them are a
    /// starting ordering — voiced continuants hold better than unvoiced
    /// friction — and are the first thing to retune if a take sounds wrong,
    /// not a measured constant.
    public var susceptibility: Double {
        switch self {
        case .vowel, .vowelExtension: 1
        case .sonorant: 0.55
        case .voicedFricative: 0.4
        case .voicelessFricative: 0.12
        case .plosive, .marker, .boundary: 0
        }
    }
}

public enum Phonology {
    public static let primaryStress: Character = "ˈ"
    public static let secondaryStress: Character = "ˌ"

    private static let members: [(PhonemeClass, String)] = [
        // Monophthongs and the halves of the diphthongs espeak splits.
        (.vowel, "aeiouyæøœɐɑɒɔɘəɚɛɜɝɞɤɨɪɯɵɶʉʊʌʏᵻε"),
        // Not sounds of their own: they say the vowel before them is held longer.
        (.vowelExtension, "ːˑ˞"),
        // Voiced and continuant. These hold without turning into noise.
        (.sonorant, "mnŋɱɲɳɴlɫɭʎʟɹɻrɾɽʀɺjwɥɰ"),
        // Voiced friction. Holds, but becomes a buzz well before a vowel would.
        (.voicedFricative, "vðzʒʐʑʝɣʁʕβɦɮʋ"),
        // Unvoiced friction. Holding one is just a longer hiss.
        (.voicelessFricative, "fθsʃçxχɸʂɕɬħhʍɧ"),
        // Closure and burst. Holding one does not lengthen a sound, it invents a gap.
        (.plosive, "pbtdkɡgqcɟɢʔʈɖɓɗʄɠʛʡʢʦʘǀǁǂǃʙⱱ"),
        // Stress, aspiration and articulatory detail. No duration to give.
        (.marker, "ˈˌʰʲʷˤ\u{0303}\u{032A}\u{032F}\u{0329}\u{0327}\u{033A}\u{033B}\u{031D}\u{030A}↓↑"),
    ]

    private static let lookup: [Character: PhonemeClass] = {
        var table: [Character: PhonemeClass] = [:]
        for (name, symbols) in members {
            for symbol in symbols { table[symbol] = name }
        }
        return table
    }()

    /// Anything not named above — punctuation, digits, the word space — is a
    /// boundary rather than a guess, so an unexpected symbol is never stretched.
    public static func phonemeClass(_ symbol: Character) -> PhonemeClass {
        lookup[symbol] ?? .boundary
    }

    public static func phonemeClass(_ symbol: String) -> PhonemeClass {
        guard symbol.count == 1, let ch = symbol.first else { return .boundary }
        return phonemeClass(ch)
    }

    public static func isVowelish(_ symbol: String) -> Bool {
        let c = phonemeClass(symbol)
        return c == .vowel || c == .vowelExtension
    }

    /// The stress marks espeak writes immediately before the syllable they
    /// belong to, which is what makes an accent addressable without a
    /// syllabifier.
    public static func isStress(_ symbol: String) -> Bool {
        symbol == String(primaryStress) || symbol == String(secondaryStress)
    }
}
