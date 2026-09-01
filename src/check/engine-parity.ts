/**
 * Parity against the Swift build, run separately from the core checks because
 * this one loads a model and they must never.
 *
 * The numbers on the right are what the Swift engine produced for the same
 * input, captured from `vfrender`. If these drift apart, the two platforms have
 * stopped sounding the same and somebody needs to know which one moved.
 */
import { VoiceEngine } from "../main/engine.js";
import { defaultSettings } from "../core/settings.js";
import { join } from "path";

const resources = join(process.cwd(), "resources");
const profile = VoiceEngine.bundledProfiles(resources)[0];
if (!profile) { console.log("no bundled voice found"); process.exit(1); }
const engine = await VoiceEngine.open(profile, resources);

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => {
  ok ? pass++ : fail++;
  if (!ok) console.log(`  FAIL ${what}`);
};

// Phonemes, byte-for-byte against the Swift engine.
const phonemeCases: [string, string][] = [
  ["The room was quiet, and nobody moved.", "ðə ɹˈuːm wʌz kwˈaɪət, ænd nˈoʊbɑːdi mˈuːvd"],
  ["Snepssen",                              "snˈɛpsən"],
  ["Kubrick",                               "kˈʌbɹɪk"],
  ["Siobhan",                               "ʃɪvˈɔːn"],
  ["The room was quiet — and nobody moved.","ðə ɹˈuːm wʌz kwˈaɪət; ænd nˈoʊbɑːdi mˈuːvd"],
  ["The room was quiet—and nobody moved.",  "ðə ɹˈuːm wʌz kwˈaɪət; ænd nˈoʊbɑːdi mˈuːvd"],
  ["mixed CaSe.",                           "mˈɪkst kˈɑː sˈiː"],
  ["It costs $4.99 today.",                 "ɪt kˈɔsts fˈɔːɹ dˈɑːlɚz nˈaɪnti nˈaɪn tədˈeɪ"],
];

// The NORTH/FORCE vowel, one word at a time — the way the Swift numbers were
// captured, and deliberately not as a phrase: espeak assigns secondary stress
// to a word inside one, so `before` alone is `bᵻfˈɔːɹ` and `before` in a
// six-word run is `bᵻfˌɔːɹ`. Both are right. Comparing across that difference
// would be comparing two different questions.
//
// This is the set that exposed the espeak-ng version gap: with the package's
// own bundled data every one of these came back with `oː` where the model was
// trained on `ɔː`.
const northForce: [string, string][] = [
  ["four", "fˈɔːɹ"], ["before", "bᵻfˈɔːɹ"], ["more", "mˈɔːɹ"], ["door", "dˈɔːɹ"],
  ["important", "ɪmpˈɔːɹtənt"], ["course", "kˈɔːɹs"], ["report", "ɹᵻpˈɔːɹt"],
  ["support", "səpˈɔːɹt"],
];
const settings = defaultSettings();
for (const [text, want] of phonemeCases) {
  const { phonemes } = await engine.phonemesFor(text, settings);
  check(phonemes === want, `phonemes ${JSON.stringify(text)}\n       got  ${JSON.stringify(phonemes)}\n       want ${JSON.stringify(want)}`);
}

for (const [word, want] of northForce) {
  const { phonemes } = await engine.phonemesFor(word, defaultSettings());
  check(phonemes === want, `NORTH/FORCE ${word}: got ${phonemes} want ${want}`);
}

// Durations, with noise_w at zero so the duration predictor is deterministic.
const deterministic = { ...settings, noiseW: 0 };
const durationCases: [string, number][] = [
  ["Welcome back to the channel.", 1.637],
  ["Today we are looking at something a little different, and I want to explain it properly.", 4.888],
];
for (const [text, want] of durationCases) {
  const samples = await engine.renderSentence(text, deterministic);
  const secs = samples.length / engine.sampleRate;
  check(Math.abs(secs - want) < 0.01,
        `duration ${JSON.stringify(text.slice(0, 40))} got ${secs.toFixed(3)}s want ${want}s`);
  console.log(`  ${secs.toFixed(3)}s  (swift ${want}s)  ${text.slice(0, 46)}`);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
