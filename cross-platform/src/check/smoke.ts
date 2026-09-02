/**
 * An end-to-end pass with no window: render a real script through the engine,
 * assemble it, resample, normalise and write a WAV, then read the file back and
 * check it is what was promised.
 *
 * Exists because "the app launches" and "the app works" are different claims,
 * and only one of them can be made without a screen.
 */
import { VoiceEngine } from "../main/engine.js";
import { defaultSettings } from "../core/settings.js";
import { parseScript } from "../core/script.js";
import { integratedLUFS, truePeakDBTP } from "../core/loudness.js";
import { writeWav, resample } from "./../main/audio.js";
import { writeFileSync, readFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

const text = `Welcome back to the channel. Today we are looking at something a little different.

Now, some awkward cases. Dr. Smith paid $4.99 on Jan. 3rd, i.e. last Tuesday, at approximately 3.5% interest. The U.S. and the U.K. disagree about this.

"Quoted speech," she said, "should survive the parser." And ellipses... they trail off. A single word. Yes.

Snepssen is not a word espeak has ever seen. Neither is Kubrick, nor nginx, nor Siobhan, nor Worcestershire.`;

const resources = join(process.cwd(), "resources");
const profile = VoiceEngine.bundledProfiles(resources)[0]!;
const engine = await VoiceEngine.open(profile, resources);
const settings = defaultSettings();

const script = parseScript(text);
console.log(`${script.sentences.length} sentences, ${text.split(/\s+/).length} words`);

// The abbreviation rule, which is the one a long script exposes.
const oneLine = script.sentences.find(s => s.text.startsWith("Dr."));
console.log(`  abbreviations: ${oneLine ? "one sentence ✓" : "SPLIT ✗"}`);

const dictionary = [
  { id: "1", word: "Snepssen", ipa: "snˈuːpsɔːn", scope: "global" as const, enabled: true },
  { id: "2", word: "Kubrick",  ipa: "kjˈuːbɹɪk",  scope: "global" as const, enabled: true },
];

const t0 = Date.now();
const rendered = await engine.render(script, settings, dictionary);
const audio = engine.assemble(rendered);
const elapsed = (Date.now() - t0) / 1000;
const secs = audio.length / engine.sampleRate;
console.log(`  ${secs.toFixed(2)}s of audio in ${elapsed.toFixed(2)}s (${(secs / elapsed).toFixed(1)}x realtime)`);

// Did the dictionary land?
for (const e of dictionary) {
  const hit = script.sentences.find(s => s.text.toLowerCase().includes(e.word.toLowerCase()));
  if (!hit) continue;
  const r = await engine.phonemesFor(hit.text, settings, [e]);
  console.log(`  dictionary ${e.word}: ${r.applied.has(e.word.toLowerCase()) ? "applied ✓" : "DID NOT APPLY ✗"}`);
}

// Export exactly as the app does: resample, measure, gain, write.
const rate = 48000, ceiling = -1, target = -14;
let out = resample(audio, engine.sampleRate, rate);
const before = integratedLUFS(out, rate);
let gain = target - before;
const peak = truePeakDBTP(out, rate);
let held = false;
if (peak + gain > ceiling) { gain = ceiling - peak; held = true; }
const g = Math.pow(10, gain / 20);
out = Float32Array.from(out, v => Math.max(-1, Math.min(1, v * g)));
// `os.tmpdir()`, not "/tmp". On Windows the literal resolves to C:\tmp,
// which does not exist, so writeFileSync throws ENOENT and the whole smoke
// test exits 1 -- which is exactly how this failed in CI while passing on
// macOS and Linux. Every other path in the project already goes through an
// API that knows what platform it is on; this one was written on a Mac.
const path = join(tmpdir(), "vfx-smoke.wav");
writeFileSync(path, writeWav(out, rate, 16));
console.log(`  ${before.toFixed(1)} LUFS -> ${integratedLUFS(out, rate).toFixed(1)} LUFS (${gain >= 0 ? "+" : ""}${gain.toFixed(1)} dB)${held ? " [held back by the ceiling]" : ""}`);

// Read it back and check the header describes the body.
const d = readFileSync(path);
const ok = d.subarray(0, 4).toString() === "RIFF" && d.subarray(8, 12).toString() === "WAVE";
const declaredRate = d.readUInt32LE(24), bits = d.readUInt16LE(34), dataBytes = d.readUInt32LE(40);
console.log(`  file: ${ok ? "RIFF/WAVE" : "NOT A WAV"} | ${declaredRate} Hz | ${bits}-bit | ${(dataBytes / (declaredRate * 2)).toFixed(2)}s`);
const fine = ok && declaredRate === rate && bits === 16 && dataBytes === out.length * 2;
console.log(fine ? "\nend to end: OK" : "\nend to end: FAILED");
process.exit(fine ? 0 : 1);
