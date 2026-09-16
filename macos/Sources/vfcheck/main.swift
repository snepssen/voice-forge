import Foundation
import VoiceForgeCore

// The whole test harness. A plain executable that asserts and exits non-zero,
// exactly as gfcheck is -- and under the same rule: it must never link
// VoiceForgeTTS. This project's subject is what the engine does, so the thing
// that measures it has to be the cheap part.
final class Checks {
    var passed = 0, failed = 0, suite = ""
    func suite(_ name: String) { suite = name }
    func expect(_ ok: Bool, _ what: String, line: Int = #line) {
        if ok { passed += 1 } else { failed += 1; print("  FAIL [\(suite)] \(what)  (line \(line))") }
    }
    func equal<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
        if a == b { passed += 1 } else {
            failed += 1; print("  FAIL [\(suite)] \(what): \(a) != \(b)  (line \(line))")
        }
    }
    func close(_ a: Double, _ b: Double, _ tolerance: Double, _ what: String, line: Int = #line) {
        if abs(a - b) <= tolerance { passed += 1 } else {
            failed += 1
            print("  FAIL [\(suite)] \(what): \(a) is not within \(tolerance) of \(b)  (line \(line))")
        }
    }
    func note(_ s: String) { print("  note [\(suite)] \(s)") }
}
let c = Checks()

// ------------------------------------------------------------------ identity
c.suite("product identity")
do {
    let version = try String(contentsOfFile: "VERSION", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    c.equal(version, "0.1.0", "the source tree identifies Voice Forge 0.1.0")
    let manifest = try String(contentsOfFile: "Package.swift", encoding: .utf8)
    c.expect(!manifest.contains("\"vfcheck\", dependencies: [\"VoiceForgeCore\", \"VoiceForgeTTS\"]"),
             "vfcheck does not link the TTS stack")
    c.expect(manifest.contains(".executableTarget(name: \"vfcheck\", dependencies: [\"VoiceForgeCore\"])"),
             "and depends on the core alone")
} catch { c.expect(false, "identity files load: \(error)") }

// -------------------------------------------------------------------- script
c.suite("script")
do {
    let s = Script.parse("One two. Three four!\n\nFive, six; seven. Eight?")
    c.equal(s.sentences.count, 4, "four sentences")
    c.equal(s.paragraphCount, 2, "in two paragraphs")
    c.equal(s.sentences[1].terminator, "!", "a terminator is kept")
    c.expect(s.sentences[1].endsParagraph, "and the last of a paragraph knows it")
    c.expect(!s.sentences[0].endsParagraph, "the first does not")
    c.equal(s.sentences[2].clauseBreaks, 2, "clause breaks are counted")
    c.equal(s.wordCount, 8, "words are counted")
    c.equal(s.sentences[0].expressionKey, "d4a88e5d:0",
            "a sentence has the same cross-platform expression key")
    c.equal(Script.parse("Earlier. One two.").sentences[1].expressionKey,
            s.sentences[0].expressionKey,
            "and inserting an earlier sentence does not move its performance")
    let repeated = Script.parse("Again. Again.")
    c.expect(repeated.sentences[0].expressionKey != repeated.sentences[1].expressionKey,
             "repeated copy can still carry two different performances")

    // The one case that bites in written-for-speech copy.
    let money = Script.parse("It costs $4.99 today. That is all.")
    c.equal(money.sentences.count, 2, "a decimal point does not end a sentence")

    let dash = Script.parse("He paused — then spoke.")
    c.equal(dash.sentences[0].clauseBreaks, 1, "an em dash is a clause break")
    let hyphen = Script.parse("A well-made thing.")
    c.equal(hyphen.sentences[0].clauseBreaks, 0, "a hyphen is not")
    c.equal(Script.parse("").sentences.count, 0, "empty text is an empty script")

    // Abbreviations. Found by stress-testing a long script: "Dr. Smith paid
    // $4.99 on Jan. 3rd, i.e. last Tuesday" came out as four utterances, `Dr.`
    // alone being a 0.63-second "sentence" with its own falling intonation and
    // its own gap. It never crashed. It just read like a broken machine.
    let abbrev = Script.parse("Dr. Smith paid $4.99 on Jan. 3rd, i.e. last Tuesday, at 3.5% interest.")
    c.equal(abbrev.sentences.count, 1, "a title, a month, a Latin abbreviation and two decimals are one sentence")
    let initialism = Script.parse("The U.S. and the U.K. disagree about this.")
    c.equal(initialism.sentences.count, 1, "and so are two initialisms")
    c.equal(Script.parse("Call at 9 a.m. or 5 p.m. tomorrow.").sentences.count, 1,
            "and times")
    c.equal(Script.parse("Mr. Smith, Mrs. Jones and Prof. Hall met.").sentences.count, 1,
            "several titles in one sentence")

    // The rule must not swallow real sentence ends. A "next word is lowercase"
    // test was tried first and did exactly that -- it merged "ALL CAPS
    // SHOUTING. mixed CaSe." into one utterance, and people write scripts in
    // lowercase all the time.
    c.equal(Script.parse("ALL CAPS SHOUTING. mixed CaSe. and more.").sentences.count, 3,
            "informal lowercase sentences still split")
    c.equal(Script.parse("one. two. three.").sentences.count, 3,
            "a lowercase script is not one long sentence")
    c.equal(Script.parse("It ended. Then it began.").sentences.count, 2,
            "an ordinary pair still splits")
    c.equal(Script.parse("Really? Yes! Fine.").sentences.count, 3,
            "question and exclamation marks always end a sentence")

    // A URL and an email have stops with no space after them.
    c.equal(Script.parse("Visit https://example.com/path?q=1 or write to a@b.com today.")
                .sentences.count, 1,
            "a URL and an email address are not sentence boundaries")
    c.equal(Script.parse("Pi is 3.14159 and e is 2.71828.").sentences.count, 1,
            "decimals are not either")

    // An em dash only reaches espeak as a clause break when it has spaces.
    // Measured: "quiet — and" phonemizes to `kwˈaɪət; ænd` -- a semicolon,
    // which is why `;` and `—` calibrate to the same number -- while
    // "quiet—and" gives `kwˈaɪət ænd`, byte-identical to writing no dash at
    // all. The pause dial names `—` among the marks it gives room to, so for
    // `word—word`, which is how most people type one, it was giving room to a
    // break that was not there.
    c.equal(Script.spacedEmDashes("quiet—and"), "quiet — and", "an unspaced em dash gets its spaces")
    c.equal(Script.spacedEmDashes("quiet — and"), "quiet — and", "a spaced one is left alone")
    c.equal(Script.spacedEmDashes("quiet— and"), "quiet — and", "and a half-spaced one is completed")
    c.equal(Script.spacedEmDashes("quiet —and"), "quiet — and", "from either side")
    c.equal(Script.spacedEmDashes("no dashes here"), "no dashes here", "text without one is untouched")
    c.equal(Script.spacedEmDashes("a—b—c"), "a — b — c", "several in a row")
    // A hyphen joins rather than separates, and espeak correctly runs
    // `hyphenated-words` together as one phoneme run. It must not be touched.
    c.equal(Script.spacedEmDashes("hyphenated-words"), "hyphenated-words",
            "a hyphen is not an em dash and is left alone")

    // Currency. espeak reads the symbol first and the number after, in every
    // currency: "dollar four point nine nine", "pound four point nine nine",
    // "euros four point nine nine", "yen four hundred". Nobody says that.
    c.equal(Script.spokenCurrency("It costs $4.99 today."), "It costs 4 dollars 99 today.",
            "an amount is spoken before its currency")
    c.equal(Script.spokenCurrency("$1"), "1 dollar", "one is singular")
    c.equal(Script.spokenCurrency("$4"), "4 dollars", "and more than one is not")
    c.equal(Script.spokenCurrency("$4.00"), "4 dollars", "a round amount drops its zeros")
    c.equal(Script.spokenCurrency("$1.00"), "1 dollar", "and stays singular")
    c.equal(Script.spokenCurrency("$1.50"), "1 dollar 50", "one and a half is still one dollar")
    c.equal(Script.spokenCurrency("$4.05"), "4 dollars oh 5",
            "a leading-zero minor part is read the way a price is read")
    c.equal(Script.spokenCurrency("$1,250"), "1,250 dollars", "thousands separators survive")
    c.equal(Script.spokenCurrency("£4.50"), "4 pounds 50", "pounds")
    c.equal(Script.spokenCurrency("€4.99"), "4 euros 99", "euros")
    c.equal(Script.spokenCurrency("¥400"), "400 yen", "yen takes no plural")
    c.equal(Script.spokenCurrency("₩5000"), "5000 won", "nor does won")
    c.equal(Script.spokenCurrency("₹4"), "4 rupees", "rupees do")
    c.equal(Script.spokenCurrency("Pay $5 or £3, either way."), "Pay 5 dollars or 3 pounds, either way.",
            "several in one sentence")

    // A symbol that is not money must survive. `$` appears in code samples and
    // shell prompts, and rewriting those would be the silent-rewriting problem
    // this rule is otherwise careful to avoid.
    c.equal(Script.spokenCurrency("Use $PATH and $HOME."), "Use $PATH and $HOME.",
            "a symbol not followed by a digit is left alone")
    c.equal(Script.spokenCurrency("costs money"), "costs money", "text with no symbol is untouched")
    c.equal(Script.spokenCurrency("$3.14159"), "3.14159 dollars",
            "more than two decimal places is not a minor unit")
}

// ------------------------------------------------------ performance markup
c.suite("performance markup")
do {
    c.equal(PerformanceMarkup.parse("Say *this* now."), [
        .text("Say ", focused: false), .text("this", focused: true),
        .text(" now.", focused: false),
    ], "asterisks mark one focused run without becoming spoken text")
    c.equal(PerformanceMarkup.parse("Wait [[beat:short]] then [[BEAT]] go [[beat:long]]."), [
        .text("Wait ", focused: false), .beat(.short),
        .text(" then ", focused: false), .beat(.medium),
        .text(" go ", focused: false), .beat(.long), .text(".", focused: false),
    ], "named beats parse case-insensitively")
    c.equal(PerformanceMarkup.spokenText("I *really* mean it [[beat]] now."),
            "I really mean it now.", "directions are absent from the spoken copy")
    c.equal(PerformanceMarkup.wordCount("I *really* mean it [[beat]] now."), 5,
            "directions do not inflate the word count")
    c.equal(PerformanceMarkup.parse("A lone * stays literal."),
            [.text("A lone * stays literal.", focused: false)],
            "an unmatched focus mark never eats the rest of a sentence")
    c.equal(PerformanceMarkup.spokenText("Two * three * four."), "Two * three * four.",
            "spaced multiplication-style stars are not mistaken for focus")
    let counts = PerformanceMarkup.cueCounts("*One* [[beat]] and *two* [[beat:long]].")
    c.equal(counts.focus, 2, "focus runs are counted for the take")
    c.equal(counts.beats, 2, "as are beats")
}

// --------------------------------------------------------------- expression
c.suite("expression")
do {
    let base = SynthesisSettings()
    let none = SentenceExpression(preset: .angry, intensity: 0)
    c.equal(none.applying(to: base), base, "zero intensity leaves Piper neutral")
    c.expect(SentenceExpression(preset: .happy).applying(to: base).lengthScale < base.lengthScale,
             "happy starts from a quicker delivery")
    c.expect(SentenceExpression(preset: .intimate).applying(to: base).lengthScale > base.lengthScale,
             "intimate starts from a slower delivery")

    let dry: [Float] = [0, 0.25, -0.25, 0.5, -0.5, 0]
    c.equal(ExpressionDSP.process(dry, from: .init(), to: .init(),
                                  transitionSeconds: 0.2, sampleRate: 22_050), dry,
            "neutral tone is bit-for-bit transparent")
    let shaped = ExpressionDSP.process(dry, from: .init(),
                                       to: SentenceExpression(preset: .angry).tone,
                                       transitionSeconds: 0.2, sampleRate: 22_050)
    c.expect(!shaped.isEmpty, "expression treatment produces audio")
    c.expect(shaped.allSatisfy(\.isFinite), "and produces finite samples")
    c.close(Double(shaped[0]), Double(dry[0]), 0.000_001,
            "an expression transition begins in the preceding state")
    let sustained = (0 ..< 4_000).map { Float(sin(Double($0) * 0.1) * 0.2) }
    let safe = ExpressionDSP.process(sustained, from: .init(),
                                     to: SentenceExpression(preset: .happy).tone,
                                     transitionSeconds: 0, sampleRate: 22_050)
    c.equal(safe.count, sustained.count, "linear tone shaping cannot warp the spoken contour")
    c.expect((safe.map { abs($0) }.max() ?? 0) < 0.5, "the treatment has safe headroom")
    for rate in [22_050.0, 48_000.0] {
        for preset in ExpressionPreset.allCases {
            let input: [Float] = (0 ..< 4_096).map { i in
                Float(0.35 * sin(Double(i) * 0.13) + 0.2 * sin(Double(i) * 1.37))
            }
            let tone = SentenceExpression(preset: preset).tone
            let full = ExpressionDSP.process(input, from: .init(), to: tone,
                                             transitionSeconds: 0.02, sampleRate: rate)
            let half = ExpressionDSP.process(input.map { $0 * 0.5 }, from: .init(), to: tone,
                                             transitionSeconds: 0.02, sampleRate: rate)
            c.expect(full.count == input.count && zip(full, half).allSatisfy {
                $0.isFinite && abs($0 * 0.5 - $1) < 0.000_001
            }, "\(preset) at \(rate) preserves length and amplitude linearity")
        }
    }
}

// ---------------------------------------------------------------- phonology
c.suite("phonology")
do {
    c.equal(Phonology.phonemeClass("o"), .vowel, "a diphthong's first half is a vowel")
    c.equal(Phonology.phonemeClass("ʊ"), .vowel, "and so is its second")
    c.equal(Phonology.phonemeClass("ː"), .vowelExtension, "the length mark is pure duration")
    c.equal(Phonology.phonemeClass("l"), .sonorant, "a liquid holds")
    c.equal(Phonology.phonemeClass("z"), .voicedFricative, "voiced friction holds less well")
    c.equal(Phonology.phonemeClass("s"), .voicelessFricative, "a hiss barely at all")
    c.equal(Phonology.phonemeClass("t"), .plosive, "and a stop not at all")
    c.equal(Phonology.phonemeClass("ˈ"), .marker, "stress is a mark, not a sound")
    c.equal(Phonology.phonemeClass(" "), .boundary, "an unlisted symbol is never stretched")
    c.equal(Phonology.phonemeClass("\u{0000}"), .boundary, "nor is one nobody anticipated")
    // The rejection this whole class map exists to encode.
    c.equal(PhonemeClass.plosive.susceptibility, 0, "a plosive can never be held")
    c.expect(PhonemeClass.vowel.susceptibility > PhonemeClass.sonorant.susceptibility
             && PhonemeClass.sonorant.susceptibility > PhonemeClass.voicedFricative.susceptibility
             && PhonemeClass.voicedFricative.susceptibility > PhonemeClass.voicelessFricative.susceptibility
             && PhonemeClass.voicelessFricative.susceptibility > PhonemeClass.plosive.susceptibility,
             "and the order runs from the vowel down to the stop")
    for klass in PhonemeClass.allCases {
        c.expect(klass.susceptibility >= 0 && klass.susceptibility <= 1,
                 "\(klass.rawValue) takes a sensible share of a stretch")
    }
}

// -------------------------------------------------------------- timing plan
c.suite("timing plan")
do {
    // The engine's layout, by hand, so this suite still never loads a model:
    // every symbol is followed by the blank that carries its release.
    func layout(_ phonemes: String) -> TokenLayout {
        var slots: [TokenSlot] = []
        var word = 0, index = 0
        func push(_ symbol: String, _ kind: TokenSlot.Kind, _ w: Int) {
            slots.append(TokenSlot(index: index, symbol: symbol, kind: kind, word: w))
            index += 1
        }
        push("^", .frame, -1); push("^", .blank, -1)
        for scalar in phonemes.unicodeScalars {
            let key = String(scalar)
            let spoken = key != " "
            push(key, .symbol, spoken ? word : -1)
            push(key, .blank, spoken ? word : -1)
            if !spoken { word += 1 }
        }
        push("$", .frame, -1)
        return TokenLayout(ids: slots.map { _ in 0 }, slots: slots, words: word + 1)
    }

    let stole = layout("stˈoʊl")
    c.equal(TimingPlan.wordPhonemes(stole, word: 0), "stˈoʊl", "a word reads back as its own IPA")
    c.equal(TimingPlan.nucleus(stole, word: 0).filter { $0.kind == .symbol }
                .map(\.symbol).joined(), "oʊ",
            "an accent lands on the vowel after the stress mark")
    c.equal(TimingPlan.nucleus(layout("juː"), word: 0).filter { $0.kind == .symbol }
                .map(\.symbol).joined(), "uː",
            "an unmarked one-syllable word still has a nucleus")
    c.equal(TimingPlan.nucleus(layout("stl"), word: 0), [], "a word with no vowel has none to find")

    let held = TimingPlan.durationFactors(stole, [SoundDirection(word: 0, stretch: 2)])
    func at(_ symbol: String, _ kind: TokenSlot.Kind = .symbol) -> Double {
        Double(held[stole.slots.first { $0.symbol == symbol && $0.kind == kind }!.index])
    }
    c.close(at("s"), 1.12, 0.000_001, "a held word barely moves its hiss")
    c.equal(at("t"), 1, "and does not move its stop at all")
    c.equal(at("t", .blank), 1, "nor the closure the stop trails")
    c.equal(at("o"), 2, "the vowel takes the whole direction")
    c.equal(at("o", .blank), 2, "and so does the blank carrying its release")
    c.close(at("l"), 1.55, 0.000_001, "the liquid takes rather more than half")
    c.equal(held.first!, 1, "nothing outside the word is touched")
    c.equal(held.last!, 1, "at either end")

    // The rejected "ssttoollee": a uniform stretch would move every one of these.
    c.equal(held.filter { $0 != 1 }.count, 8, "only the sounds that can be held are held")

    let accented = TimingPlan.durationFactors(stole, [SoundDirection(word: 0, accent: 0.5)])
    c.expect(accented[stole.slots.first { $0.symbol == "o" }!.index] > 1
             && accented[stole.slots.first { $0.symbol == "l" }!.index] == 1,
             "an accent alone moves the nucleus and nothing else in the word")

    let two = layout("juː stˈoʊl")
    let one = TimingPlan.durationFactors(two, [SoundDirection(word: 1, stretch: 2)])
    c.expect(TimingPlan.wordSlots(two, word: 0).allSatisfy { one[$0.index] == 1 },
             "directing one word leaves its neighbour exactly alone")

    for stretch in [0.25, 1.0, 4.0] {
        let extreme = TimingPlan.durationFactors(stole,
            [SoundDirection(word: 0, stretch: stretch, accent: 3)])
        c.expect(extreme.allSatisfy { TimingPlan.factorRange.contains(Double($0)) },
                 "a stretch of \(stretch) still lands inside the graph's range")
    }

    c.equal(TimingPlan.durationFactors(stole, []),
            [Float](repeating: 1, count: stole.ids.count),
            "no direction is a vector of ones, which the model must render unchanged")

    // Alignment comes from the model's own reported frames, not from a guess.
    c.equal(TimingPlan.sampleBounds([2, 3, 1], hop: 256), [0, 512, 1280, 1536],
            "token bounds follow the frames")
    c.close(TimingPlan.addedSeconds(base: [2, 3], actual: [2, 5], hop: 256, rate: 22_050),
            0.0232, 0.0001, "added time is reported, not assumed")

    let hop = 256, perToken = 2
    let frames = [Float](repeating: Float(perToken), count: stole.ids.count)
    let samples = stole.ids.count * perToken * hop
    let ceiling = pow(10.0, 4.5 / 20)
    let gain = TimingPlan.accentEnvelope(stole, [SoundDirection(word: 0, accentDB: 4.5)],
                                         frames: frames, samples: samples, hop: hop)
    c.equal(gain.count, samples, "the lift covers the whole take")
    c.expect(gain.allSatisfy { Double($0) >= 1 && Double($0) <= ceiling + 0.000_001 },
             "an accent lift stays within the dB it was asked for")
    c.equal(gain.first!, 1, "and starts from unity rather than stepping")

    // The fix that matters: full lift on the vowel, not on the word's midpoint.
    let bounds = TimingPlan.sampleBounds(frames, hop: hop)
    let core = TimingPlan.nucleus(stole, word: 0)
    let mid = (bounds[core.first!.index] + bounds[core.last!.index + 1]) / 2
    c.close(Double(gain[mid]), ceiling, 0.000_001,
            "the accent is at full level across its nucleus")
    let stop = stole.slots.first { $0.symbol == "t" && $0.kind == .symbol }!
    c.expect(Double(gain[bounds[stop.index]]) < ceiling,
             "and not at full level on the stop in front of it")
    c.expect(zip(gain, gain.dropFirst()).allSatisfy { abs($0 - $1) < 0.01 },
             "the lift never steps, so nothing clicks")
    let quiet = TimingPlan.accentEnvelope(stole, [SoundDirection(word: 0)],
                                          frames: frames, samples: samples, hop: hop)
    c.expect(quiet.allSatisfy { $0 == 1 }, "no lift asked for is no lift applied")

    c.equal(TimingPlan.fullAccentDB, 6, "a full accent is the level that was chosen by ear")
    c.equal(TimingPlan.accented(word: 0, stretch: 1, strength: 1).accentDB,
            TimingPlan.fullAccentDB, "one dial at full gives that level")
    c.equal(TimingPlan.accented(word: 0, stretch: 1, strength: 0).accentDB, 0,
            "and at nothing gives none")
    c.expect(TimingPlan.accented(word: 0, stretch: 1, strength: 0.5).accent > 0
             && TimingPlan.accented(word: 0, stretch: 1, strength: 0.5).accentDB > 0,
             "hold and level move together rather than separately")
    c.equal(TimingPlan.accented(word: 0, stretch: 1, strength: 4).accentDB,
            TimingPlan.fullAccentDB, "and a strength past full is held at full")
}

// ------------------------------------------------------------------ prosody
c.suite("prosody")
do {
    // Built by hand from what espeak really emits for these sentences, so the
    // suite still never loads a model.
    func stream(_ phonemes: String) -> TokenLayout {
        var slots: [TokenSlot] = []
        var word = 0, index = 0
        func push(_ symbol: String, _ kind: TokenSlot.Kind, _ w: Int) {
            slots.append(TokenSlot(index: index, symbol: symbol, kind: kind, word: w))
            index += 1
        }
        push("^", .frame, -1); push("^", .blank, -1)
        for scalar in phonemes.unicodeScalars {
            let key = String(scalar)
            let spoken = key != " "
            push(key, .symbol, spoken ? word : -1)
            push(key, .blank, spoken ? word : -1)
            if !spoken { word += 1 }
        }
        push("$", .frame, -1)
        return TokenLayout(ids: slots.map { _ in 0 }, slots: slots, words: word + 1)
    }

    // "The cat sat on the mat in the sun." -- note nine written words arrive as
    // seven groups, because espeak runs "on the" and "in the" together.
    let cat = stream("ðə kˈæt sˈæt ɔnðə mˈæt ɪnðə sˈʌn")
    let groups = Prosody.prosodicGroups(cat)
    c.equal(groups.count, 7, "a sentence is read as the groups espeak made, not its written words")
    c.equal(groups.map(\.prominence),
            [.reduced, .accented, .accented, .reduced, .accented, .reduced, .accented],
            "espeak's own stress marks say which words carry weight")

    let plan = Prosody.automaticDirections(cat)
    func on(_ word: Int) -> SoundDirection? { plan.first { $0.word == word } }
    c.expect(on(6)!.accentDB > 0, "the point of the phrase lands on its last content word")
    c.equal(plan.filter { $0.accentDB > 0 }.count, 1,
            "and only there — one phrase makes one point")
    c.expect(on(0)!.stretch < 1 && on(3)!.stretch < 1 && on(5)!.stretch < 1,
             "the unstressed words give way, so the beats come out uneven")
    let reduced = Set(groups.filter { $0.prominence == .reduced }.map(\.word))
    c.expect(plan.filter { $0.stretch < 1 }.allSatisfy { reduced.contains($0.word) },
             "and only they do — a word carrying weight is never compressed")
    c.expect(!plan.contains { $0.word == 1 },
             "a content word that is not the point is left alone")

    // Two clauses, so two points rather than one.
    let cold = stream("ɪt wʌz kˈoʊld, ɪt wʌz lˈeɪt, ænd nˈoʊbɑːdi kˈeɪm")
    let twice = Prosody.automaticDirections(cold)
    c.equal(twice.filter { $0.accentDB > 0 }.count, 3, "each clause makes its own point")
    c.expect(twice.first { $0.word == 2 }!.stretch > 1,
             "and a phrase settles at the clause mark")

    // The same word twice in a paragraph should not be hit twice.
    let seen = Prosody.spokenKeys(stream("ðə ɡˈɑːɹdən"))
    c.expect(seen.contains("ɡɑːɹdən"), "a word is remembered without its stress mark")
    let fresh = Prosody.automaticDirections(stream("ɪn ðə ɡˈɑːɹdən"))
    let again = Prosody.automaticDirections(stream("ɪn ðə ɡˈɑːɹdən"),
                                            settings: ProsodySettings(), spoken: seen)
    c.expect(again.first { $0.word == 2 }!.accentDB < fresh.first { $0.word == 2 }!.accentDB,
             "hearing it a second time steps back")

    // Every dial has to be able to turn off the rule it controls.
    let flat = Prosody.automaticDirections(cat, settings: ProsodySettings(
        focus: 0, phraseFinal: 0, deaccentRepeats: 0, contrast: 0))
    c.equal(flat, [], "turned all the way down it directs nothing at all")
    let noContrast = Prosody.automaticDirections(cat,
        settings: ProsodySettings(contrast: 0))
    c.expect(noContrast.allSatisfy { $0.stretch >= 1 }, "and contrast alone can be turned off")

    c.equal(Prosody.automaticDirections(stream("")), [], "an empty sentence is not a crash")
    c.equal(Prosody.automaticDirections(stream("ðə ɐ")).filter { $0.accentDB > 0 }.count, 0,
            "a phrase with nothing to accent makes no point rather than inventing one")
    for d in Prosody.automaticDirections(cold) {
        c.expect(TimingPlan.factorRange.contains(d.stretch) && d.accentDB <= TimingPlan.fullAccentDB,
                 "an automatic direction on \(d.word) stays inside what was approved by ear")
    }
}

// ------------------------------------------------------------------ settings
c.suite("settings")
do {
    let d = SynthesisSettings()
    c.expect(d.isWithinRanges, "the defaults sit inside the ranges the app offers")
    c.equal(d.lengthScale, 1.0, "pace defaults to the reader's measured rate")
    c.equal(d.noiseScale, 0.667, "and the other two to the voice config's own values")
    c.equal(d.noiseW, 0.8, "noise_w")
    c.equal(d.trailingPads, 2, "two trailing pads, the measured optimum")
    c.expect(d.dropFinalFullStop, "and the final full stop is dropped")

    var bad = d; bad.lengthScale = 5
    c.expect(!bad.isWithinRanges, "a value outside its range is caught")
}

// ------------------------------------------------------------------- loudness
c.suite("loudness")
do {
    // A -20 dBFS 1 kHz sine at 48 kHz. BS.1770's K-weighting is near 0 dB at
    // 1 kHz, so the answer should land close to -20 LUFS -- this is the
    // standard sanity anchor for a loudness implementation, and getting it
    // wrong by several LU is what a copied 48 kHz coefficient table does when
    // applied at another rate.
    // **Amplitude 0.1 is -23 dBFS RMS, not -20**, and LUFS is a mean-square
    // measure -- so the canonical anchor needs amplitude 0.1*sqrt(2). Getting
    // this backwards is the classic way to "find" a 3 dB bug in a correct
    // loudness implementation, and it is worth the sentence: BS.1770's -0.691
    // offset exists precisely so that a 1 kHz sine at -20 dBFS **RMS** reads
    // -20 LUFS once K-weighting's gain at 1 kHz is counted.
    let rate = 48_000.0
    let amplitude = 0.1 * 2.0.squareRoot()          // -20 dBFS RMS
    let sine = (0..<Int(rate * 3)).map {
        Float(amplitude * sin(2 * Double.pi * 1000 * Double($0) / rate))
    }
    let lufs = Loudness.integratedLUFS(sine, rate: rate)
    c.close(lufs, -20, 1.0, "a -20 dBFS 1 kHz tone measures about -20 LUFS")
    c.note(String(format: "1 kHz @ -20 dBFS, 48k: %.2f LUFS", lufs))

    // The same tone at the model's own rate must measure the same. This is the
    // check that fails if the filters are hardcoded for 48 kHz.
    let r2 = Audio.modelSampleRate
    let sine2 = (0..<Int(r2 * 3)).map {
        Float(amplitude * sin(2 * Double.pi * 1000 * Double($0) / r2))
    }
    let lufs2 = Loudness.integratedLUFS(sine2, rate: r2)
    c.close(lufs2, lufs, 0.5, "and measures the same at 22.05 kHz")
    c.note(String(format: "1 kHz @ -20 dBFS, 22.05k: %.2f LUFS", lufs2))

    // Halving amplitude is -6 dB and must move the answer by 6 LU.
    let quieter = sine.map { $0 * 0.5 }
    c.close(Loudness.integratedLUFS(quieter, rate: rate), lufs - 6, 0.2,
            "halving the amplitude moves it by 6 LU")

    c.expect(!Loudness.integratedLUFS([Float](repeating: 0, count: 96_000), rate: rate).isFinite,
             "silence has no loudness rather than a made-up floor")

    // True peak sees between samples; sample peak does not.
    let peaky: [Float] = [0, 0.9, -0.9, 0.9, -0.9, 0]
    c.expect(Loudness.truePeakDBTP(peaky, rate: rate) >= Audio.peakDBFS(peaky) - 0.01,
             "true peak is never below sample peak")

    let target = Loudness.targets.first { $0.name == "YouTube" }!
    c.equal(target.lufs, -14, "the YouTube target is -14 LUFS")
    if let n = Loudness.normalisation(for: quieter, rate: rate, target: target) {
        c.close(n.measuredLUFS + n.gainDB, -14, 0.01, "normalisation lands on the target")
    } else { c.expect(false, "a normalisation is offered for real audio") }
}

// -------------------------------------------------------------------- export
c.suite("export")
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "vf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let rate = Audio.modelSampleRate
    let tone = (0..<Int(rate * 2)).map {
        Float(0.05 * sin(2 * Double.pi * 220 * Double($0) / rate))
    }
    var settings = Export.Settings()
    settings.sampleRate = 48_000
    settings.targetLUFS = -14
    let url = tmp.appending(path: "take.wav")
    let receipt = try Export.write(tone, at: rate, to: url, settings: settings)

    c.expect(FileManager.default.fileExists(atPath: url.path), "a file is written")
    c.close(receipt.seconds, 2.0, 0.05, "the length survives resampling")
    c.close(receipt.lufsAfter, -14, 0.6, "and it lands on the loudness target")
    c.equal(receipt.clippedSamples, 0, "with nothing clipped")
    c.expect(receipt.gainApplied > 0, "a quiet source is turned up, not down")

    // The header has to say what the body is, or an editor will read noise.
    let data = try Data(contentsOf: url)
    c.equal(String(decoding: data[0..<4], as: UTF8.self), "RIFF", "RIFF header")
    c.equal(String(decoding: data[8..<12], as: UTF8.self), "WAVE", "WAVE header")
    let declaredRate = data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    c.equal(Int(declaredRate), 48_000, "the header declares the rate the file actually is")
    let bits = data[34..<36].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    c.equal(Int(bits), 16, "and the depth")
    c.equal(data.count, 44 + Int(receipt.seconds * 48_000) * 2, "and the body is the length it claims")

    // 24-bit is three bytes a sample, which is the reason this writer exists.
    var deep = settings; deep.depth = .pcm24; deep.targetLUFS = nil
    let url24 = tmp.appending(path: "take24.wav")
    let r24 = try Export.write(tone, at: rate, to: url24, settings: deep)
    let d24 = try Data(contentsOf: url24)
    c.equal(d24.count, 44 + Int(r24.seconds * 48_000) * 3, "24-bit writes three bytes a sample")
    c.equal(r24.gainApplied, 0, "and 'leave it alone' leaves the level alone")

    // The ceiling must win over the target, and say so. It takes a *quiet but
    // peaky* signal to get there -- loud audio needs no gain -- which is
    // exactly the real case: a voice recorded with plenty of headroom and one
    // hard consonant near full scale.
    var peaky = tone.map { $0 * 0.4 }               // quiet body
    for i in stride(from: 1000, to: peaky.count, by: 9000) { peaky[i] = 0.95 }
    var hot = settings; hot.targetLUFS = -14; hot.truePeakCeiling = -1
    let rHot = try Export.write(peaky, at: rate, to: tmp.appending(path: "hot.wav"), settings: hot)
    c.expect(rHot.truePeakAfter <= -1 + 0.15, "the true-peak ceiling is respected")
    c.expect(rHot.heldBackByCeiling, "and the app says the target was not reached")
} catch { c.expect(false, "export checks threw: \(error)") }

// ------------------------------------------------------ pronunciation dictionary
c.suite("pronunciation")
do {
    // **The real vocabulary, not a convenient fixture.** The first version of
    // this suite invented a vocabulary that excluded ASCII `r`, so "an ASCII r
    // is refused" passed -- against a voice where `r` is present and is the IPA
    // alveolar trill. The fixture was asserting something untrue of the thing
    // it stood for. These are the symbols the bundled voices actually carry.
    let vocab: Set<String> = Set(
        ("abcdefghijklmnopqrstuvwxyzX"
         + "æçðøħŋœɐɑɒɓɔɕɖɗɘəɚɛɜɝɞɟɠɡɢɣɤɥɦɧɨɪɫɬɭɮɯɰɱɲɳɴɵɶɸɹɺɻɽɾʀʁʂʃʄʈʉʊʋʌʍʎʏʐʑʒʔʕʘʙʛʜʝʟʡʢʦʰʲʷ"
         + "ˈˌːˑˤβεθχᵻⱱ"
         + " !\"#$'(),-.0123456789:;?^_").map(String.init))

    // What actually vanishes, measured against that vocabulary.
    let slashes = PronunciationDictionary.problem(with: "/snˈɛpsən/", vocabulary: vocab)
    c.expect(slashes.isBlocking, "the slashes a dictionary quotes IPA in are refused")
    c.expect(slashes.message.contains("U+002F"), "and named by codepoint")
    c.expect(slashes.message.contains("without the brackets"),
             "with the fix said, since this is the likeliest way to get it wrong")

    let capital = PronunciationDictionary.problem(with: "Snˈɛpsən", vocabulary: vocab)
    c.expect(capital.isBlocking, "a capital letter is refused -- it has no phoneme")
    let accent = PronunciationDictionary.problem(with: "kæfˈé", vocabulary: vocab)
    c.expect(accent.isBlocking, "and so is accented Latin")

    // Worse than dropping: punctuation the model knows *as punctuation*.
    let dot = PronunciationDictionary.problem(with: "snˈɛp.sən", vocabulary: vocab)
    c.expect(dot.isBlocking, "a syllable dot is refused")
    c.expect(dot.message.contains("break the sentence"),
             "because `.` is the full-stop phoneme, not a separator")
    c.expect(dot.unknownSymbols.isEmpty, "and it is refused as punctuation, not as unknown")

    // Present, legal, and almost certainly not meant. These warn rather than
    // block: they are real IPA and somebody may mean them.
    let trill = PronunciationDictionary.problem(with: "snrepsen", vocabulary: vocab)
    c.expect(!trill.isBlocking, "an ASCII r is not blocked -- the voice really does have one")
    c.expect(trill.hasWarning, "but it is flagged")
    c.expect(trill.message.contains("trilled"), "as the trill it actually is")
    c.expect(trill.message.contains("U+0279"), "with the English r offered instead")

    let gee = PronunciationDictionary.problem(with: "ɡʊd ɡud", vocabulary: vocab)
    c.expect(!gee.hasWarning, "the IPA ɡ passes without comment")
    let asciiG = PronunciationDictionary.problem(with: "gʊd", vocabulary: vocab)
    c.expect(asciiG.hasWarning, "and the ASCII g that looks identical is flagged")

    let good = PronunciationDictionary.problem(with: "snˈɛpsən", vocabulary: vocab)
    c.expect(!good.isBlocking && !good.hasWarning, "a clean entry passes silently")
    c.expect(PronunciationDictionary.problem(with: "   ", vocabulary: vocab).isBlocking,
             "an empty entry is refused")

    // Scope. A project entry beats a global one for the same word.
    let g = PronunciationEntry(word: "Snepssen", ipa: "snˈɛpsən", scope: .global)
    let p = PronunciationEntry(word: "snepssen", ipa: "snˈɛpsɛn", scope: .project)
    let both = PronunciationDictionary(entries: [g, p])
    c.equal(both.effective.count, 1, "one word, one answer")
    c.equal(both.effective.first?.ipa, "snˈɛpsɛn", "and the project entry wins")
    c.expect(both.isShadowed(g), "the global entry is shown as shadowed")
    c.expect(!both.isShadowed(p), "the project one is not")
    c.equal(PronunciationDictionary(entries: [g]).effective.first?.ipa, "snˈɛpsən",
            "with no project entry, the global one applies")
    var off = p; off.enabled = false
    c.equal(PronunciationDictionary(entries: [g, off]).effective.first?.ipa, "snˈɛpsən",
            "and a disabled project entry stops shadowing")

    // Substitution. These are the real strings espeak produced, measured.
    let sentence = "ðə snˈɛpsən vˈɔɪs ɪz hˈɪɹ."
    let r1 = PronunciationDictionary.apply(
        [PronunciationEntry(word: "Snepssen", ipa: "snˈɛpsɛn")],
        to: sentence, defaults: ["snepssen": "snˈɛpsən"])
    c.equal(r1.phonemes, "ðə snˈɛpsɛn vˈɔɪs ɪz hˈɪɹ.", "the word is replaced in context")
    c.expect(r1.applied.contains("snepssen"), "and the entry reports that it landed")

    // Trailing punctuation must survive -- the sentence would otherwise lose
    // its full stop, which is the phoneme the ending logic depends on.
    let r2 = PronunciationDictionary.apply(
        [PronunciationEntry(word: "Kubrick", ipa: "kˈuːbɹɪk")],
        to: "aɪ wˈɑːtʃt ɐ kˈʌbɹɪk.", defaults: ["kubrick": "kˈʌbɹɪk"])
    c.equal(r2.phonemes, "aɪ wˈɑːtʃt ɐ kˈuːbɹɪk.", "punctuation on the last group survives")

    // A word that is not there must not be reported as applied.
    let r3 = PronunciationDictionary.apply(
        [PronunciationEntry(word: "Kubrick", ipa: "kˈuːbɹɪk")],
        to: "ðə snˈɛpsən vˈɔɪs.", defaults: ["kubrick": "kˈʌbɹɪk"])
    c.equal(r3.phonemes, "ðə snˈɛpsən vˈɔɪs.", "an absent word changes nothing")
    c.expect(r3.applied.isEmpty, "and is not claimed to have applied")

    // Whole groups only. A bare substring replace would rewrite the middle of
    // a longer word; this is the check that pins that shut.
    let r4 = PronunciationDictionary.apply(
        [PronunciationEntry(word: "read", ipa: "ɹˈɛd")],
        to: "ɹˈiːdɪŋ ɹˈiːd", defaults: ["read": "ɹˈiːd"])
    c.equal(r4.phonemes, "ɹˈiːdɪŋ ɹˈɛd",
            "a longer word that merely starts the same is left alone")

    // Every occurrence in a sentence is replaced -- and that is the homograph
    // limitation, stated rather than hidden: one entry cannot say "read" two
    // ways.
    let r5 = PronunciationDictionary.apply(
        [PronunciationEntry(word: "read", ipa: "ɹˈɛd")],
        to: "aɪ ɹˈiːd ɪt ænd ɹˈiːd ɪt", defaults: ["read": "ɹˈiːd"])
    c.equal(r5.phonemes, "aɪ ɹˈɛd ɪt ænd ɹˈɛd ɪt", "every occurrence is replaced")

    // Multi-word defaults: espeak turns "nginx" into two groups.
    let r6 = PronunciationDictionary.apply(
        [PronunciationEntry(word: "nginx", ipa: "ˈɛndʒɪnˌɛks")],
        to: "ðə ˈɛndʒɪn ˌɛks sˈɜːvɚ", defaults: ["nginx": "ˈɛndʒɪn ˌɛks"])
    c.equal(r6.phonemes, "ðə ˈɛndʒɪnˌɛks sˈɜːvɚ", "a word espeak split into two is matched across both")
}

// ---------------------------------------------------------------- voice notes
// A claim attached to the wrong thing. The pace dial said "the reader's own
// rate, measured to within 0.3%" under every voice. The measurement is real but
// was made on snepssen-rode against the reader's own recordings; snepssen
// was fine-tuned on generated audio and reads 31% faster on identical copy --
// 194 words a minute against 148, with commas worth 145 ms against 457.
// Printing rode's measurement under suno was simply false.
c.suite("voice notes")
do {
    c.expect(VoiceNotes.note("snepssen-rode")?.paceReference != nil,
             "the measured voice carries its measurement")
    c.expect(VoiceNotes.note("snepssen")?.paceReference == nil,
             "and the unmeasured one does not borrow it")
    let rode = VoiceNotes.paceNote(voice: "snepssen-rode", lengthScale: 1.0)
    let bundled = VoiceNotes.paceNote(voice: "snepssen", lengthScale: 1.0)
    c.expect(rode.contains("0.3%"), "rode says it is a measured likeness")
    c.expect(!bundled.contains("0.3%"),
             "suno does not claim a likeness nobody measured for it")
    c.expect(bundled.contains("performance rather than a likeness"),
             "and says the bundled voice is a performance, not a failed likeness")
    c.expect(rode != bundled, "the two voices do not say the same thing at 1.0")

    // An unknown voice must not be given somebody else's numbers either.
    let unknown = VoiceNotes.paceNote(voice: "not-a-voice", lengthScale: 1.0)
    c.expect(!unknown.contains("0.3%"), "an unknown voice claims nothing")
    c.expect(VoiceNotes.paceNote(voice: "somebody-elses-voice", lengthScale: 1.3)
                .contains("not been measured here"),
             "and an installed voice says plainly that nobody measured it")

    // A departure is described against the voice's own rate, not a shared one.
    let slow = VoiceNotes.paceNote(voice: "snepssen", lengthScale: 1.2)
    c.expect(slow.contains("20% slower"), "a departure is named in plain terms")
    c.expect(slow.contains("194"), "against this voice's own measured rate")
    c.expect(VoiceNotes.paceNote(voice: "snepssen-rode", lengthScale: 1.2).contains("148"),
             "and the other voice's against its own")
}

// ----------------------------------------------------------- export preview
// The preview has to agree with what the write actually does, or it is worse
// than not having one: a number that is confidently wrong about the file you
// are about to make. So it is checked against a real write, not on its own.
c.suite("export preview")
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "vf-p-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let rate = Audio.modelSampleRate
    func tone(_ amp: Double) -> [Float] {
        (0..<Int(rate * 2)).map { Float(amp * sin(2 * Double.pi * 220 * Double($0) / rate)) }
    }
    var settings = Export.Settings()
    settings.sampleRate = 48_000
    settings.targetLUFS = -14

    // A quiet, reachable case.
    let quiet = tone(0.05)
    guard let p1 = Export.preview(quiet, at: rate, settings: settings) else {
        throw NSError(domain: "p", code: 1)
    }
    let r1 = try Export.write(quiet, at: rate, to: tmp.appending(path: "a.wav"), settings: settings)
    c.close(p1.resultingLUFS, r1.lufsAfter, 0.15, "the preview matches the file it predicts")
    c.close(p1.lufs, r1.lufsBefore, 0.01, "and agrees about the level before gain")
    c.equal(p1.heldBack, r1.heldBackByCeiling, "and about whether the ceiling bit")
    c.expect(!p1.heldBack, "a quiet, peak-clean source reaches its target")
    c.close(p1.shortfall, 0, 0.01, "with nothing left on the table")

    // The peaky case that cannot reach the target on gain alone -- the one a
    // single dry voice actually hits.
    var peaky = tone(0.02)
    for i in stride(from: 500, to: peaky.count, by: 7000) { peaky[i] = 0.95 }
    guard let p2 = Export.preview(peaky, at: rate, settings: settings) else {
        throw NSError(domain: "p", code: 2)
    }
    let r2 = try Export.write(peaky, at: rate, to: tmp.appending(path: "b.wav"), settings: settings)
    c.expect(p2.heldBack, "a peaky source is predicted to fall short")
    c.equal(p2.heldBack, r2.heldBackByCeiling, "and the file agrees")
    c.close(p2.resultingLUFS, r2.lufsAfter, 0.15, "and lands where the preview said")
    c.expect(p2.shortfall > 1, "with the shortfall named (\(String(format: "%.1f", p2.shortfall)) dB)")
    c.note(String(format: "peaky source: %.1f LUFS, peak %.1f dBTP -> %.1f LUFS (%.1f dB short)",
                  p2.lufs, p2.truePeak, p2.resultingLUFS, p2.shortfall))

    // "Leave it alone" must predict no change at all.
    var asIs = settings; asIs.targetLUFS = nil
    guard let p3 = Export.preview(quiet, at: rate, settings: asIs) else {
        throw NSError(domain: "p", code: 3)
    }
    c.close(p3.resultingLUFS, p3.lufs, 0.001, "leaving it alone changes nothing")
    c.expect(!p3.heldBack, "and cannot be held back by a ceiling it is not aiming at")
} catch { c.expect(false, "export preview checks threw: \(error)") }

// --------------------------------------------------------------- calibration
c.suite("pause calibration")
do {
    let probes = PauseCalibration.probes(for: ",")
    c.expect(probes.count >= 5, "the probe set is more than one line")
    for p in probes {
        c.expect(p.with.contains(","), "the probe under test carries the mark")
        c.expect(!p.without.contains(","), "and its pair does not")
        c.equal(p.with.replacingOccurrences(of: ",", with: ""), p.without,
                "the pair differs by the mark and nothing else")
    }
    let cal = PauseCalibration(
        voice: "snepssen-rode", lengthScale: 1.0,
        marks: [.init(mark: ",", mean: 0.18, minimum: 0.09, maximum: 0.31, samples: 6)],
        secondsPerClausePad: 0.012)
    c.expect(cal.clausePauseDescription(pads: 0).contains("as the model writes it"),
             "with no pads it reports what the model does on its own")
    c.expect(cal.clausePauseDescription(pads: 4).contains("–"),
             "and with pads it reports a range, not a single confident number")
    var other = SynthesisSettings(); other.lengthScale = 1.3
    c.expect(!cal.describes(other, voice: "snepssen-rode"),
             "a calibration does not survive a change of pace")
    c.expect(!cal.describes(SynthesisSettings(), voice: "snepssen"),
             "nor transfer between voices")
    c.expect(cal.describes(SynthesisSettings(), voice: "snepssen-rode"),
             "but does describe the settings it was taken at")
}

// --------------------------------------------------------------------- audio
c.suite("audio")
do {
    let rate = 22_050.0
    c.equal(Audio.silence(seconds: 0.5, at: rate).count, 11_025, "silence is the length asked for")
    c.equal(Audio.silence(seconds: -1, at: rate).count, 0, "a negative gap is no gap")
    c.close(Audio.seconds([Float](repeating: 0, count: 22_050), at: rate), 1.0, 0.001,
            "and length converts back to seconds")

    // Deliberately unequal runs: 200 quiet, 200 loud, 600 quiet. Equal runs
    // would make the answer a tie-break rather than a measurement.
    var buf = [Float](repeating: 0, count: 1000)
    for i in 200..<400 { buf[i] = 0.5 }
    let run = Audio.longestQuietRun(buf, minimumLength: 10)
    c.equal(run?.start, 400, "the longest quiet run is found")
    c.equal(run?.length, 600, "with its length")
    c.equal(Audio.quietHead(buf), 200, "and the quiet head")
    c.equal(Audio.quietTail(buf), 600, "and the quiet tail")

    let (gained, clipped) = Audio.applyGain([0.5, -0.5], 4)
    c.equal(clipped, 2, "clipping is counted, never hidden")
    c.equal(gained, [1.0, -1.0], "and the result is limited rather than wrapped")
}

print("")
print("\(c.passed) passed, \(c.failed) failed")
exit(c.failed == 0 ? 0 : 1)
