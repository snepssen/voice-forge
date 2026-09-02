/**
 * The whole test harness, ported alongside the logic it checks.
 *
 * A plain script that asserts and exits non-zero, exactly as `vfcheck` is on
 * the Swift side — and under the same rule: **it must never load a model.**
 * That keeps it fast and keeps the checks honest about which layer they cover.
 *
 * The assertions are deliberately the same assertions, in the same order, with
 * the same wording. That is the whole point of porting them: if the Swift and
 * TypeScript cores ever disagree, one of these two suites goes red.
 */
import * as S from "../core/script.js";
import { defaultSettings, isWithinRanges, ranges } from "../core/settings.js";
import { paceNote, noteFor } from "../core/voiceNotes.js";
import { integratedLUFS, truePeakDBTP, loudnessTargets } from "../core/loudness.js";
import * as P from "../core/pronunciation.js";

let passed = 0, failed = 0, suite = "";
const setSuite = (s: string) => { suite = s; };
function expect(ok: boolean, what: string) {
  if (ok) passed++; else { failed++; console.log(`  FAIL [${suite}] ${what}`); }
}
function equal<T>(a: T, b: T, what: string) {
  const ok = JSON.stringify(a) === JSON.stringify(b);
  if (ok) passed++; else { failed++; console.log(`  FAIL [${suite}] ${what}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`); }
}
function close(a: number, b: number, tol: number, what: string) {
  if (Math.abs(a - b) <= tol) passed++;
  else { failed++; console.log(`  FAIL [${suite}] ${what}: ${a} is not within ${tol} of ${b}`); }
}
const note = (s: string) => console.log(`  note [${suite}] ${s}`);

// ------------------------------------------------------------------- script
setSuite("script");
{
  const s = S.parseScript("One two. Three four!\n\nFive, six; seven. Eight?");
  equal(s.sentences.length, 4, "four sentences");
  equal(S.paragraphCount(s), 2, "in two paragraphs");
  equal(s.sentences[1]!.terminator, "!", "a terminator is kept");
  expect(s.sentences[1]!.endsParagraph, "and the last of a paragraph knows it");
  expect(!s.sentences[0]!.endsParagraph, "the first does not");
  equal(s.sentences[2]!.clauseBreaks, 2, "clause breaks are counted");
  equal(S.wordCount(s), 8, "words are counted");

  equal(S.parseScript("It costs $4.99 today. That is all.").sentences.length, 2,
        "a decimal point does not end a sentence");
  equal(S.parseScript("He paused — then spoke.").sentences[0]!.clauseBreaks, 1,
        "an em dash is a clause break");
  equal(S.parseScript("A well-made thing.").sentences[0]!.clauseBreaks, 0, "a hyphen is not");
  equal(S.parseScript("").sentences.length, 0, "empty text is an empty script");

  // Abbreviations. "Dr. Smith paid $4.99 on Jan. 3rd, i.e. last Tuesday" came
  // out as four utterances, `Dr.` alone being a 0.63-second "sentence".
  equal(S.parseScript("Dr. Smith paid $4.99 on Jan. 3rd, i.e. last Tuesday, at 3.5% interest.").sentences.length, 1,
        "a title, a month, a Latin abbreviation and two decimals are one sentence");
  equal(S.parseScript("The U.S. and the U.K. disagree about this.").sentences.length, 1,
        "and so are two initialisms");
  equal(S.parseScript("Call at 9 a.m. or 5 p.m. tomorrow.").sentences.length, 1, "and times");
  equal(S.parseScript("Mr. Smith, Mrs. Jones and Prof. Hall met.").sentences.length, 1,
        "several titles in one sentence");

  // A "next word is lowercase" test was tried and removed: people write
  // scripts in lowercase all the time.
  equal(S.parseScript("ALL CAPS SHOUTING. mixed CaSe. and more.").sentences.length, 3,
        "informal lowercase sentences still split");
  equal(S.parseScript("one. two. three.").sentences.length, 3, "a lowercase script is not one long sentence");
  equal(S.parseScript("It ended. Then it began.").sentences.length, 2, "an ordinary pair still splits");
  equal(S.parseScript("Really? Yes! Fine.").sentences.length, 3, "? and ! always end a sentence");
  equal(S.parseScript("Visit https://example.com/path?q=1 or write to a@b.com today.").sentences.length, 1,
        "a URL and an email address are not sentence boundaries");
  equal(S.parseScript("Pi is 3.14159 and e is 2.71828.").sentences.length, 1, "decimals are not either");

  // Em dashes. "quiet — and" phonemizes to a semicolon clause break;
  // "quiet—and" is byte-identical to writing no dash at all.
  equal(S.spacedEmDashes("quiet—and"), "quiet — and", "an unspaced em dash gets its spaces");
  equal(S.spacedEmDashes("quiet — and"), "quiet — and", "a spaced one is left alone");
  equal(S.spacedEmDashes("quiet— and"), "quiet — and", "and a half-spaced one is completed");
  equal(S.spacedEmDashes("quiet —and"), "quiet — and", "from either side");
  equal(S.spacedEmDashes("no dashes here"), "no dashes here", "text without one is untouched");
  equal(S.spacedEmDashes("a—b—c"), "a — b — c", "several in a row");
  equal(S.spacedEmDashes("hyphenated-words"), "hyphenated-words", "a hyphen is left alone");

  // Currency.
  equal(S.spokenCurrency("It costs $4.99 today."), "It costs 4 dollars 99 today.",
        "an amount is spoken before its currency");
  equal(S.spokenCurrency("$1"), "1 dollar", "one is singular");
  equal(S.spokenCurrency("$4"), "4 dollars", "and more than one is not");
  equal(S.spokenCurrency("$4.00"), "4 dollars", "a round amount drops its zeros");
  equal(S.spokenCurrency("$1.00"), "1 dollar", "and stays singular");
  equal(S.spokenCurrency("$1.50"), "1 dollar 50", "one and a half is still one dollar");
  equal(S.spokenCurrency("$4.05"), "4 dollars oh 5", "a leading-zero minor part is read as a price");
  equal(S.spokenCurrency("$1,250"), "1,250 dollars", "thousands separators survive");
  equal(S.spokenCurrency("£4.50"), "4 pounds 50", "pounds");
  equal(S.spokenCurrency("€4.99"), "4 euros 99", "euros");
  equal(S.spokenCurrency("¥400"), "400 yen", "yen takes no plural");
  equal(S.spokenCurrency("₩5000"), "5000 won", "nor does won");
  equal(S.spokenCurrency("₹4"), "4 rupees", "rupees do");
  equal(S.spokenCurrency("Pay $5 or £3, either way."), "Pay 5 dollars or 3 pounds, either way.",
        "several in one sentence");
  equal(S.spokenCurrency("Use $PATH and $HOME."), "Use $PATH and $HOME.",
        "a symbol not followed by a digit is left alone");
  equal(S.spokenCurrency("costs money"), "costs money", "text with no symbol is untouched");
  equal(S.spokenCurrency("$3.14159"), "3.14159 dollars", "more than two decimals is not a minor unit");
}

// ----------------------------------------------------------------- settings
setSuite("settings");
{
  const d = defaultSettings();
  expect(isWithinRanges(d), "the defaults sit inside the ranges the app offers");
  equal(d.lengthScale, 1.0, "pace defaults to as-trained");
  equal(d.noiseScale, 0.667, "and the other two to the voice config's own values");
  equal(d.noiseW, 0.8, "noise_w");
  equal(d.trailingPads, 2, "two trailing pads, the measured optimum");
  expect(d.dropFinalFullStop, "and the final full stop is dropped");
  expect(d.spokenCurrency, "currency is read the way it is said, by default");
  expect(!isWithinRanges({ ...d, lengthScale: 5 }), "a value outside its range is caught");
  equal(ranges.lengthScale[1], 2.0, "the pace range tops out at 2.0");
}

// --------------------------------------------------------------- voice notes
setSuite("voice notes");
{
  expect(noteFor("snepssen-rode")?.paceReference != null, "the measured voice carries its measurement");
  expect(noteFor("snepssen")?.paceReference == null, "and the unmeasured one does not borrow it");
  const rode = paceNote("snepssen-rode", 1.0);
  const bundled = paceNote("snepssen", 1.0);
  expect(rode.includes("0.3%"), "rode says it is a measured likeness");
  expect(!bundled.includes("0.3%"), "the bundled voice does not claim a likeness nobody measured");
  expect(bundled.includes("performance rather than a likeness"),
         "and says the bundled voice is a performance, not a failed likeness");
  expect(rode !== bundled, "the two voices do not say the same thing at 1.0");
  expect(!paceNote("not-a-voice", 1.0).includes("0.3%"), "an unknown voice claims nothing");
  expect(paceNote("somebody-elses-voice", 1.3).includes("not been measured here"),
         "and an installed voice says plainly that nobody measured it");
  expect(paceNote("snepssen", 1.2).includes("20% slower"), "a departure is named in plain terms");
  expect(paceNote("snepssen", 1.2).includes("194"), "against this voice's own measured rate");
  expect(paceNote("snepssen-rode", 1.2).includes("148"), "and the other voice's against its own");
}

// ----------------------------------------------------------------- loudness
setSuite("loudness");
{
  // Amplitude 0.1 is -23 dBFS RMS, not -20, and LUFS is a mean-square measure.
  // BS.1770's -0.691 offset exists so a 1 kHz sine at -20 dBFS **RMS** reads
  // -20 LUFS once K-weighting's gain at 1 kHz is counted.
  const rate = 48000, amplitude = 0.1 * Math.SQRT2;
  const sine = (r: number, n: number) =>
    Float32Array.from({ length: Math.floor(r * n) }, (_, i) => amplitude * Math.sin(2 * Math.PI * 1000 * i / r));
  const lufs = integratedLUFS(sine(rate, 3), rate);
  close(lufs, -20, 1.0, "a -20 dBFS 1 kHz tone measures about -20 LUFS");
  note(`1 kHz @ -20 dBFS, 48k: ${lufs.toFixed(2)} LUFS`);

  // The check that fails if the filters are hardcoded for 48 kHz.
  const lufs2 = integratedLUFS(sine(22050, 3), 22050);
  close(lufs2, lufs, 0.5, "and measures the same at 22.05 kHz");
  note(`1 kHz @ -20 dBFS, 22.05k: ${lufs2.toFixed(2)} LUFS`);

  const quieter = Float32Array.from(sine(rate, 3), v => v * 0.5);
  close(integratedLUFS(quieter, rate), lufs - 6, 0.2, "halving the amplitude moves it by 6 LU");
  expect(!isFinite(integratedLUFS(new Float32Array(96000), rate)),
         "silence has no loudness rather than a made-up floor");
  const peaky = Float32Array.from([0, 0.9, -0.9, 0.9, -0.9, 0]);
  let samplePeak = 0; for (const v of peaky) samplePeak = Math.max(samplePeak, Math.abs(v));
  expect(truePeakDBTP(peaky, rate) >= 20 * Math.log10(samplePeak) - 0.01,
         "true peak is never below sample peak");
  equal(loudnessTargets.find(t => t.name === "YouTube")!.lufs, -14, "the YouTube target is -14 LUFS");
}

// ------------------------------------------------------------ pronunciation
setSuite("pronunciation");
{
  // The real vocabulary, not a convenient fixture: `r` IS present as the IPA
  // alveolar trill, and an earlier fixture that omitted it was asserting
  // something untrue of the thing it stood for.
  const vocab = new Set([...("abcdefghijklmnopqrstuvwxyzX"
    + "æçðøħŋœɐɑɒɓɔɕɖɗɘəɚɛɜɝɞɟɠɡɢɣɤɥɦɧɨɪɫɬɭɮɯɰɱɲɳɴɵɶɸɹɺɻɽɾʀʁʂʃʄʈʉʊʋʌʍʎʏʐʑʒʔʕʘʙʛʜʝʟʡʢʦʰʲʷ"
    + "ˈˌːˑˤβεθχᵻⱱ" + " !\"#$'(),-.0123456789:;?^_")]);

  const slashes = P.checkPronunciation("/snˈɛpsən/", vocab);
  expect(P.isBlocking(slashes), "the slashes a dictionary quotes IPA in are refused");
  expect(P.problemMessage(slashes).includes("U+002F"), "and named by codepoint");
  expect(P.problemMessage(slashes).includes("without the brackets"), "with the fix said");
  expect(P.isBlocking(P.checkPronunciation("Snˈɛpsən", vocab)), "a capital letter is refused");
  expect(P.isBlocking(P.checkPronunciation("kæfˈé", vocab)), "and so is accented Latin");

  const dot = P.checkPronunciation("snˈɛp.sən", vocab);
  expect(P.isBlocking(dot), "a syllable dot is refused");
  expect(P.problemMessage(dot).includes("break the sentence"), "because `.` is the full-stop phoneme");
  expect(dot.unknownSymbols.length === 0, "and it is refused as punctuation, not as unknown");

  const trill = P.checkPronunciation("snrepsen", vocab);
  expect(!P.isBlocking(trill), "an ASCII r is not blocked — the voice really does have one");
  expect(P.hasWarning(trill), "but it is flagged");
  expect(P.problemMessage(trill).includes("trilled"), "as the trill it actually is");
  expect(P.problemMessage(trill).includes("U+0279"), "with the English r offered instead");
  expect(!P.hasWarning(P.checkPronunciation("ɡʊd", vocab)), "the IPA ɡ passes without comment");
  expect(P.hasWarning(P.checkPronunciation("gʊd", vocab)), "and the ASCII g that looks identical is flagged");
  const good = P.checkPronunciation("snˈɛpsən", vocab);
  expect(!P.isBlocking(good) && !P.hasWarning(good), "a clean entry passes silently");
  expect(P.isBlocking(P.checkPronunciation("   ", vocab)), "an empty entry is refused");

  const g: P.PronunciationEntry = { id: "1", word: "Snepssen", ipa: "snˈɛpsən", scope: "global", enabled: true };
  const p: P.PronunciationEntry = { id: "2", word: "snepssen", ipa: "snˈɛpsɛn", scope: "project", enabled: true };
  equal(P.effectiveEntries([g, p]).length, 1, "one word, one answer");
  equal(P.effectiveEntries([g, p])[0]!.ipa, "snˈɛpsɛn", "and the project entry wins");
  expect(P.isShadowed(g, [g, p]), "the global entry is shown as shadowed");
  expect(!P.isShadowed(p, [g, p]), "the project one is not");
  equal(P.effectiveEntries([g])[0]!.ipa, "snˈɛpsən", "with no project entry, the global one applies");
  equal(P.effectiveEntries([g, { ...p, enabled: false }])[0]!.ipa, "snˈɛpsən",
        "and a disabled project entry stops shadowing");

  const d = (k: string, v: string) => new Map([[k, v]]);
  const r1 = P.applyDictionary([{ ...g, ipa: "snˈɛpsɛn" }], "ðə snˈɛpsən vˈɔɪs ɪz hˈɪɹ.", d("snepssen", "snˈɛpsən"));
  equal(r1.phonemes, "ðə snˈɛpsɛn vˈɔɪs ɪz hˈɪɹ.", "the word is replaced in context");
  expect(r1.applied.has("snepssen"), "and the entry reports that it landed");

  const r2 = P.applyDictionary([{ id: "3", word: "Kubrick", ipa: "kˈuːbɹɪk", scope: "global", enabled: true }],
                               "aɪ wˈɑːtʃt ɐ kˈʌbɹɪk.", d("kubrick", "kˈʌbɹɪk"));
  equal(r2.phonemes, "aɪ wˈɑːtʃt ɐ kˈuːbɹɪk.", "punctuation on the last group survives");

  const r3 = P.applyDictionary([{ id: "4", word: "Kubrick", ipa: "kˈuːbɹɪk", scope: "global", enabled: true }],
                               "ðə snˈɛpsən vˈɔɪs.", d("kubrick", "kˈʌbɹɪk"));
  equal(r3.phonemes, "ðə snˈɛpsən vˈɔɪs.", "an absent word changes nothing");
  expect(r3.applied.size === 0, "and is not claimed to have applied");

  const r4 = P.applyDictionary([{ id: "5", word: "read", ipa: "ɹˈɛd", scope: "global", enabled: true }],
                               "ɹˈiːdɪŋ ɹˈiːd", d("read", "ɹˈiːd"));
  equal(r4.phonemes, "ɹˈiːdɪŋ ɹˈɛd", "a longer word that merely starts the same is left alone");

  const r5 = P.applyDictionary([{ id: "6", word: "read", ipa: "ɹˈɛd", scope: "global", enabled: true }],
                               "aɪ ɹˈiːd ɪt ænd ɹˈiːd ɪt", d("read", "ɹˈiːd"));
  equal(r5.phonemes, "aɪ ɹˈɛd ɪt ænd ɹˈɛd ɪt", "every occurrence is replaced");

  const r6 = P.applyDictionary([{ id: "7", word: "nginx", ipa: "ˈɛndʒɪnˌɛks", scope: "global", enabled: true }],
                               "ðə ˈɛndʒɪn ˌɛks sˈɜːvɚ", d("nginx", "ˈɛndʒɪn ˌɛks"));
  equal(r6.phonemes, "ðə ˈɛndʒɪnˌɛks sˈɜːvɚ", "a word espeak split into two is matched across both");
}

console.log("");
console.log(`${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
