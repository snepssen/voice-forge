import CEspeakNG
import Foundation
import VoiceForgeCore

/// Text to phonemes, via the vendored `libespeak-ng.a` (CEspeakNG).
///
/// This is a direct Swift port of the C logic already verified working in
/// this project's Python tooling (`tools-python/piper1-gpl/src/piper/espeakbridge.c`)
/// — the clause-terminator constants and their masking are copied from there
/// exactly, not re-derived, since getting the bit arithmetic subtly wrong
/// here would silently misplace sentence/clause boundaries rather than fail
/// loudly.
public final class EspeakPhonemizer {
    public struct Clause {
        public var phonemes: String
        public var terminator: String
        public var endOfSentence: Bool
    }

    public enum PhonemizerError: LocalizedError {
        case initializationFailed
        case voiceNotFound(String)
        case allocationFailed

        public var errorDescription: String? {
            switch self {
            case .initializationFailed: return "espeak-ng failed to initialize"
            case .voiceNotFound(let voice): return "espeak-ng has no voice named \(voice)"
            case .allocationFailed: return "could not allocate a text buffer for phonemization"
            }
        }
    }

    // Mirrors espeakbridge.c's #defines exactly.
    private static let intonationFullStop: Int32 = 0x0000_0000
    private static let intonationComma: Int32 = 0x0000_1000
    private static let intonationQuestion: Int32 = 0x0000_2000
    private static let intonationExclamation: Int32 = 0x0000_3000
    private static let typeClause: Int32 = 0x0004_0000
    private static let typeSentence: Int32 = 0x0008_0000

    private static let clausePeriod = 40 | intonationFullStop | typeSentence
    private static let clauseQuestion = 40 | intonationQuestion | typeSentence
    private static let clauseExclamation = 45 | intonationExclamation | typeSentence
    private static let clauseComma = 20 | intonationComma | typeClause
    private static let clauseColon = 30 | intonationFullStop | typeClause
    private static let clauseSemicolon = 30 | intonationComma | typeClause

    // espeak_Initialize is process-global state, not per-instance -- it may
    // only run once no matter how many phonemizers get created. `init` is
    // called once, at engine construction, never from a hot or concurrent
    // path -- `nonisolated(unsafe)` is Swift's sanctioned escape hatch for
    // exactly this "safe by construction, not by the compiler's proof" case.
    private nonisolated(unsafe) static var initialized = false

    public init(dataDirectory: URL, voice: String) throws {
        if !Self.initialized {
            let result = dataDirectory.path.withCString { path in
                espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, path, 0)
            }
            guard result >= 0 else { throw PhonemizerError.initializationFailed }
            Self.initialized = true
        }
        let status = voice.withCString { espeak_SetVoiceByName($0) }
        guard status == EE_OK else { throw PhonemizerError.voiceNotFound(voice) }
    }

    /// **No respellings.** Gateway Forge carries two, for `I-There` and
    /// `REBAL`, because those are its own vocabulary and espeak reads them
    /// wrong. A general text-to-speech tool must not quietly rewrite the words
    /// it was given: if a name comes out wrong here, the fix belongs in front
    /// of the user, as text they can edit, not hidden at the point where text
    /// becomes sound. A pronunciation dictionary is worth building; silently
    /// substituting is not.
    static func respelled(_ text: String) -> String { text }

    /// Text to phoneme clauses -- each roughly a sentence or sub-clause,
    /// carrying its own terminator punctuation and whether it ends a sentence.
    public func clauses(for text: String) throws -> [Clause] {
        guard let buffer = strdup(Self.respelled(text)) else { throw PhonemizerError.allocationFailed }
        defer { free(buffer) }

        var out: [Clause] = []
        var cursor: UnsafeRawPointer? = UnsafeRawPointer(buffer)
        while cursor != nil {
            var terminator: Int32 = 0
            guard let phonemesPtr = espeak_TextToPhonemesWithTerminator(
                &cursor, espeakCHARS_AUTO, espeakPHONEMES_IPA, &terminator
            ) else { break }

            let phonemes = String(cString: phonemesPtr)
            let masked = terminator & 0x000F_FFFF
            let terminatorStr: String
            switch masked {
            case Self.clausePeriod: terminatorStr = "."
            case Self.clauseQuestion: terminatorStr = "?"
            case Self.clauseExclamation: terminatorStr = "!"
            case Self.clauseComma: terminatorStr = ","
            case Self.clauseColon: terminatorStr = ":"
            case Self.clauseSemicolon: terminatorStr = ";"
            default: terminatorStr = ""
            }
            let endOfSentence = (terminator & Self.typeSentence) == Self.typeSentence
            out.append(Clause(phonemes: phonemes, terminator: terminatorStr, endOfSentence: endOfSentence))
        }
        return out
    }

    /// One flattened phoneme string for a whole passage — deliberately not
    /// split back into per-sentence pieces. Splitting into independent
    /// inference calls is exactly what caused the sentence-boundary glitch
    /// found this session (each chunk starts cold, with no real audio
    /// context); the fix was architectural, not a phonemizer concern, but it
    /// means this is the one method `PiperSpeechEngine` should call.
    /// - Parameter dropFinalStop: drop the very last `.` terminator, keeping
    ///   every interior one. See `PiperSpeechEngine.dropFinalFullStop`.
    public func phonemize(_ text: String, dropFinalStop: Bool = false) throws -> String {
        var result = ""
        for clause in try clauses(for: text) {
            // Strip (lang) switch flags the same way phonemize_espeak.py does
            // -- they surround words from a language other than the current
            // voice and aren't phonemes themselves.
            var stripped = clause.phonemes
            while let open = stripped.firstIndex(of: "("),
                  let close = stripped[open...].firstIndex(of: ")") {
                stripped.removeSubrange(open...close)
            }
            result += stripped + clause.terminator
            // A space after **every** terminator, not only the comma-like
            // ones. Flattening used to join sentences bare -- `hˈɪɹ.aɪ
            // wˈɛlkʌm` -- which is a shape the model never saw in training,
            // since Piper phonemizes one sentence at a time. `campfire-calling`
            // is the case that proved it costs something: the owner heard a
            // phantom "-eth" on "I welcome connection" in all eight draws of
            // the flattened line, and none at all when that sentence was
            // rendered on its own.
            if !clause.terminator.isEmpty { result += " " }
        }
        result = result.trimmingCharacters(in: .whitespaces)
        // Only a full stop, and only the final one: `?` and `!` carry meaning
        // this voice should keep, and interior stops are what separate
        // sentences inside one flattened call.
        if dropFinalStop, result.hasSuffix(".") {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result.decomposedStringWithCanonicalMapping
    }
}
