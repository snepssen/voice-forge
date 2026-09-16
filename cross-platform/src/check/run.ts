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
import * as E from "../core/expression.js";
import * as M from "../core/performanceMarkup.js";
import * as PH from "../core/phonology.js";
import * as T from "../core/timingPlan.js";
import * as PR from "../core/prosody.js";
import type { TokenLayout, TokenSlot } from "../main/engine.js";

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
  equal(s.sentences[0]!.expressionKey, "d4a88e5d:0",
        "a sentence has the same cross-platform expression key");
  equal(S.parseScript("Earlier. One two.").sentences[1]!.expressionKey,
        s.sentences[0]!.expressionKey,
        "and inserting an earlier sentence does not move its performance");
  const repeated = S.parseScript("Again. Again.");
  expect(repeated.sentences[0]!.expressionKey !== repeated.sentences[1]!.expressionKey,
         "repeated copy can still carry two different performances");

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

// ------------------------------------------------------ performance markup
setSuite("performance markup");
{
  equal(M.parsePerformanceMarkup("Say *this* now."), [
    { kind: "text", text: "Say ", focused: false },
    { kind: "text", text: "this", focused: true },
    { kind: "text", text: " now.", focused: false },
  ], "asterisks mark one focused run without becoming spoken text");
  equal(M.parsePerformanceMarkup("Wait [[beat:short]] then [[BEAT]] go [[beat:long]]."), [
    { kind: "text", text: "Wait ", focused: false }, { kind: "beat", beat: "short" },
    { kind: "text", text: " then ", focused: false }, { kind: "beat", beat: "medium" },
    { kind: "text", text: " go ", focused: false }, { kind: "beat", beat: "long" },
    { kind: "text", text: ".", focused: false },
  ], "named beats parse case-insensitively");
  equal(M.spokenText("I *really* mean it [[beat]] now."), "I really mean it now.",
        "directions are absent from the spoken copy");
  equal(M.performanceWordCount("I *really* mean it [[beat]] now."), 5,
        "directions do not inflate the word count");
  equal(M.parsePerformanceMarkup("A lone * stays literal."),
        [{ kind: "text", text: "A lone * stays literal.", focused: false }],
        "an unmatched focus mark never eats the rest of a sentence");
  equal(M.spokenText("Two * three * four."), "Two * three * four.",
        "spaced multiplication-style stars are not mistaken for focus");
  equal(M.cueCounts("*One* [[beat]] and *two* [[beat:long]]."), { focus: 2, beats: 2 },
        "focus runs and beats are counted for the take");
}

// --------------------------------------------------------------- expression
setSuite("expression");
{
  const base = defaultSettings();
  const none: E.SentenceExpression = { preset: "angry", intensity: 0, transitionSeconds: 0.18 };
  equal(E.expressionSettings(base, none), base, "zero intensity leaves Piper neutral");
  expect(E.expressionSettings(base, { ...none, preset: "happy", intensity: 1 }).lengthScale < base.lengthScale,
         "happy starts from a quicker delivery");
  expect(E.expressionSettings(base, { ...none, preset: "intimate", intensity: 1 }).lengthScale > base.lengthScale,
         "intimate starts from a slower delivery");

  const dry = Float32Array.from([0, 0.25, -0.25, 0.5, -0.5, 0]);
  const neutral: E.ExpressionTone = {
    lowShelfDB: 0, presenceDB: 0, highShelfDB: 0, outputDB: 0,
  };
  equal([...E.applyExpression(dry, neutral, neutral, 0.2, 22050)], [...dry],
        "neutral tone is bit-for-bit transparent");
  const shaped = E.applyExpression(dry, neutral,
    E.toneFor({ preset: "angry", intensity: 1, transitionSeconds: 0.2 }), 0.2, 22050);
  expect(shaped.length > 0, "expression treatment produces audio");
  expect([...shaped].every(Number.isFinite), "and produces finite samples");
  close(shaped[0]!, dry[0]!, 0.000001, "an expression transition begins in the preceding state");
  const sustained = Float32Array.from({ length: 4000 }, (_, i) => Math.sin(i * 0.1) * 0.2);
  const safe = E.applyExpression(sustained, neutral,
    E.toneFor({ ...none, preset: "happy", intensity: 1 }), 0, 22050);
  equal(safe.length, sustained.length, "linear tone shaping cannot warp the spoken contour");
  expect(Math.max(...safe.map(Math.abs)) < 0.5, "the treatment has safe headroom");
  // A sample peak below zero did not detect the old waveshaper distortion.
  // Linear processing must give the same result before/after scaling input.
  for (const rate of [22050, 48000]) for (const preset of E.expressionPresets) {
    const tone = E.toneFor({ preset, intensity: 1, transitionSeconds: 0.02 });
    const input = Float32Array.from({ length: 4096 }, (_, i) =>
      0.35 * Math.sin(i * 0.13) + 0.2 * Math.sin(i * 1.37));
    const full = E.applyExpression(input, neutral, tone, 0.02, rate);
    const half = E.applyExpression(input.map(v => v * 0.5), neutral, tone, 0.02, rate);
    expect(full.length === input.length && full.every((v, i) =>
      Number.isFinite(v) && Math.abs(v * 0.5 - half[i]!) < 1e-6),
      `${preset} at ${rate} preserves length and amplitude linearity`);
  }
}

// ---------------------------------------------------------------- phonology
setSuite("phonology");
{
  equal(PH.phonemeClass("oʊ"[0]!), "vowel", "a diphthong's first half is a vowel");
  equal(PH.phonemeClass("ʊ"), "vowel", "and so is its second");
  equal(PH.phonemeClass("ː"), "vowelExtension", "the length mark is pure duration");
  equal(PH.phonemeClass("l"), "sonorant", "a liquid holds");
  equal(PH.phonemeClass("z"), "voicedFricative", "voiced friction holds less well");
  equal(PH.phonemeClass("s"), "voicelessFricative", "a hiss barely at all");
  equal(PH.phonemeClass("t"), "plosive", "and a stop not at all");
  equal(PH.phonemeClass("ˈ"), "marker", "stress is a mark, not a sound");
  equal(PH.phonemeClass(" "), "boundary", "an unlisted symbol is never stretched");
  equal(PH.phonemeClass(" "), "boundary", "nor is one nobody anticipated");
  // The rejection this whole class map exists to encode.
  equal(PH.susceptibility.plosive, 0, "a plosive can never be held");
  expect(PH.susceptibility.vowel > PH.susceptibility.sonorant
    && PH.susceptibility.sonorant > PH.susceptibility.voicedFricative
    && PH.susceptibility.voicedFricative > PH.susceptibility.voicelessFricative
    && PH.susceptibility.voicelessFricative > PH.susceptibility.plosive,
    "and the order runs from the vowel down to the stop");
  for (const c of PH.phonemeClasses) {
    expect(PH.susceptibility[c] >= 0 && PH.susceptibility[c] <= 1,
           `${c} takes a sensible share of a stretch`);
  }
}

// -------------------------------------------------------------- timing plan
setSuite("timing plan");
{
  // The engine's layout, by hand, so this suite still never loads a model:
  // every symbol is followed by the blank that carries its release.
  const layout = (phonemes: string): TokenLayout => {
    const slots: TokenSlot[] = [];
    let word = 0, index = 0;
    const push = (symbol: string, kind: TokenSlot["kind"], w: number) =>
      slots.push({ index: index++, symbol, kind, word: w });
    push("^", "frame", -1); push("^", "blank", -1);
    for (const ch of [...phonemes]) {
      const spoken = ch !== " ";
      push(ch, "symbol", spoken ? word : -1);
      push(ch, "blank", spoken ? word : -1);
      if (!spoken) word++;
    }
    push("$", "frame", -1);
    return { ids: slots.map(() => 0), slots, words: word + 1 };
  };

  const stole = layout("stˈoʊl");
  equal(T.wordPhonemes(stole, 0), "stˈoʊl", "a word reads back as its own IPA");
  equal(T.nucleus(stole, 0).filter(s => s.kind === "symbol").map(s => s.symbol).join(""),
        "oʊ", "an accent lands on the vowel after the stress mark");
  equal(T.nucleus(layout("juː"), 0).filter(s => s.kind === "symbol").map(s => s.symbol).join(""),
        "uː", "an unmarked one-syllable word still has a nucleus");
  equal(T.nucleus(layout("stl"), 0), [], "a word with no vowel has none to find");

  const held = T.durationFactors(stole, [{ word: 0, stretch: 2, accent: 0, accentDB: 0 }]);
  const at = (symbol: string, kind: TokenSlot["kind"] = "symbol") =>
    held[stole.slots.find(s => s.symbol === symbol && s.kind === kind)!.index]!;
  close(at("s"), 1.12, 1e-6, "a held word barely moves its hiss");
  equal(at("t"), 1, "and does not move its stop at all");
  equal(at("t", "blank"), 1, "nor the closure the stop trails");
  equal(at("o"), 2, "the vowel takes the whole direction");
  equal(at("o", "blank"), 2, "and so does the blank carrying its release");
  close(at("l"), 1.55, 1e-6, "the liquid takes rather more than half");
  equal(held[0]!, 1, "nothing outside the word is touched");
  equal(held[held.length - 1]!, 1, "at either end");

  // The rejected "ssttoollee": a uniform stretch would move every one of these.
  const uniform = [...held].filter(v => v !== 1).length;
  equal(uniform, 8, "only the sounds that can be held are held");

  const accented = T.durationFactors(stole, [{ word: 0, stretch: 1, accent: 0.5, accentDB: 0 }]);
  expect(accented[stole.slots.find(s => s.symbol === "o")!.index]! > 1
    && accented[stole.slots.find(s => s.symbol === "l")!.index]! === 1,
    "an accent alone moves the nucleus and nothing else in the word");

  const two = layout("juː stˈoʊl");
  const one = T.durationFactors(two, [{ word: 1, stretch: 2, accent: 0, accentDB: 0 }]);
  expect(T.wordSlots(two, 0).every(s => one[s.index] === 1),
         "directing one word leaves its neighbour exactly alone");

  for (const stretch of [0.25, 1, 4]) {
    const extreme = T.durationFactors(stole, [{ word: 0, stretch, accent: 3, accentDB: 0 }]);
    expect([...extreme].every(v => v >= T.factorRange.min && v <= T.factorRange.max),
           `a stretch of ${stretch} still lands inside the graph's range`);
  }

  equal(T.durationFactors(stole, []), new Float32Array(stole.ids.length).fill(1),
        "no direction is a vector of ones, which the model must render unchanged");

  // Alignment comes from the model's own reported frames, not from a guess.
  equal(T.sampleBounds([2, 3, 1], 256), [0, 512, 1280, 1536], "token bounds follow the frames");
  close(T.addedSeconds([2, 3], [2, 5], 256, 22050), 0.0232, 1e-4, "added time is reported, not assumed");

  const hop = 256, perToken = 2;
  const frames = new Array(stole.ids.length).fill(perToken);
  const samples = stole.ids.length * perToken * hop;
  const ceiling = Math.pow(10, 4.5 / 20);
  const gain = T.accentEnvelope(stole, [{ word: 0, stretch: 1, accent: 0, accentDB: 4.5 }],
                                frames, samples, hop);
  equal(gain.length, samples, "the lift covers the whole take");
  expect([...gain].every(v => v >= 1 && v <= ceiling + 1e-6),
         "an accent lift stays within the dB it was asked for");
  equal(gain[0]!, 1, "and starts from unity rather than stepping");

  // The fix that matters: full lift on the vowel, not on the word's midpoint.
  const span = (slots: TokenSlot[]) => {
    const bounds = T.sampleBounds(frames, hop);
    return [bounds[slots[0]!.index]!, bounds[slots[slots.length - 1]!.index + 1]!] as const;
  };
  const [coreStart, coreEnd] = span(T.nucleus(stole, 0));
  const mid = Math.floor((coreStart + coreEnd) / 2);
  close(gain[mid]!, ceiling, 1e-6, "the accent is at full level across its nucleus");
  const stop = stole.slots.find(s => s.symbol === "t" && s.kind === "symbol")!;
  expect(gain[T.sampleBounds(frames, hop)[stop.index]!]! < ceiling,
         "and not at full level on the stop in front of it");
  expect([...gain].every((v, i) => i === 0 || Math.abs(v - gain[i - 1]!) < 0.01),
         "the lift never steps, so nothing clicks");
  const quiet = T.accentEnvelope(stole, [{ word: 0, stretch: 1, accent: 0, accentDB: 0 }],
                                 frames, samples, hop);
  expect([...quiet].every(v => v === 1), "no lift asked for is no lift applied");

  equal(T.fullAccentDB, 6, "a full accent is the level that was chosen by ear");
  equal(T.accentedDirection(0, 1, 1).accentDB, T.fullAccentDB,
        "one dial at full gives that level");
  equal(T.accentedDirection(0, 1, 0).accentDB, 0, "and at nothing gives none");
  expect(T.accentedDirection(0, 1, 0.5).accent > 0
    && T.accentedDirection(0, 1, 0.5).accentDB > 0,
    "hold and level move together rather than separately");
  equal(T.accentedDirection(0, 1, 4).accentDB, T.fullAccentDB,
        "and a strength past full is held at full");
}

// ------------------------------------------------------------------ prosody
setSuite("prosody");
{
  // Built by hand from what espeak really emits for these sentences, so the
  // suite still never loads a model.
  const stream = (phonemes: string): TokenLayout => {
    const slots: TokenSlot[] = [];
    let word = 0, index = 0;
    const push = (symbol: string, kind: TokenSlot["kind"], w: number) =>
      slots.push({ index: index++, symbol, kind, word: w });
    push("^", "frame", -1); push("^", "blank", -1);
    for (const ch of [...phonemes]) {
      const spoken = ch !== " ";
      push(ch, "symbol", spoken ? word : -1);
      push(ch, "blank", spoken ? word : -1);
      if (!spoken) word++;
    }
    push("$", "frame", -1);
    return { ids: slots.map(() => 0), slots, words: word + 1 };
  };

  // "The cat sat on the mat in the sun." — note nine written words arrive as
  // seven groups, because espeak runs "on the" and "in the" together.
  const cat = stream("ðə kˈæt sˈæt ɔnðə mˈæt ɪnðə sˈʌn");
  const groups = PR.prosodicGroups(cat);
  equal(groups.length, 7, "a sentence is read as the groups espeak made, not its written words");
  equal(groups.map(g => g.prominence),
        ["reduced", "accented", "accented", "reduced", "accented", "reduced", "accented"],
        "espeak's own stress marks say which words carry weight");

  const plan = PR.automaticDirections(cat);
  const on = (word: number) => plan.find(d => d.word === word);
  expect(on(6)!.accentDB > 0, "the point of the phrase lands on its last content word");
  expect(plan.filter(d => d.accentDB > 0).length === 1,
         "and only there — one phrase makes one point");
  expect(on(0)!.stretch < 1 && on(3)!.stretch < 1 && on(5)!.stretch < 1,
         "the unstressed words give way, so the beats come out uneven");
  const reduced = new Set(groups.filter(g => g.prominence === "reduced").map(g => g.word));
  expect(plan.filter(d => d.stretch < 1).every(d => reduced.has(d.word)),
         "and only they do — a word carrying weight is never compressed");
  expect(!plan.some(d => d.word === 1), "a content word that is not the point is left alone");

  // Two clauses, so two points rather than one.
  const cold = stream("ɪt wʌz kˈoʊld, ɪt wʌz lˈeɪt, ænd nˈoʊbɑːdi kˈeɪm");
  const twice = PR.automaticDirections(cold);
  equal(twice.filter(d => d.accentDB > 0).length, 3, "each clause makes its own point");
  expect(twice.find(d => d.word === 2)!.stretch > 1,
         "and a phrase settles at the clause mark");

  // The same word twice in a paragraph should not be hit twice.
  const seen = PR.spokenKeys(stream("ðə ɡˈɑːɹdən"));
  expect(seen.has("ɡɑːɹdən"), "a word is remembered without its stress mark");
  const fresh = PR.automaticDirections(stream("ɪn ðə ɡˈɑːɹdən"));
  const again = PR.automaticDirections(stream("ɪn ðə ɡˈɑːɹdən"), PR.defaultProsody(), seen);
  expect(again.find(d => d.word === 2)!.accentDB < fresh.find(d => d.word === 2)!.accentDB,
         "hearing it a second time steps back");

  // Every dial has to be able to turn the rule off it controls.
  const flat = PR.automaticDirections(cat,
    { ...PR.defaultProsody(), focus: 0, phraseFinal: 0, contrast: 0 });
  equal(flat, [], "turned all the way down it directs nothing at all");
  const noContrast = PR.automaticDirections(cat, { ...PR.defaultProsody(), contrast: 0 });
  expect(noContrast.every(d => d.stretch >= 1), "and contrast alone can be turned off");

  equal(PR.automaticDirections(stream("")), [], "an empty sentence is not a crash");
  equal(PR.automaticDirections(stream("ðə ɐ")).filter(d => d.accentDB > 0).length, 0,
        "a phrase with nothing to accent makes no point rather than inventing one");
  for (const d of PR.automaticDirections(cold)) {
    expect(d.stretch >= 0.5 && d.stretch <= 2.5 && d.accentDB <= T.fullAccentDB,
           `an automatic direction on ${d.word} stays inside what was approved by ear`);
  }
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
