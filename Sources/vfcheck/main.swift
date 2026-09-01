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
    c.expect(bundled.contains("where it was trained"),
             "and says plainly what 1.0 means for it instead")
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
