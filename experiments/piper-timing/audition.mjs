/** Run after building cross-platform. Experimental graph only; no app changes.
 * Usage: node experiments/piper-timing/audition.mjs ORIGINAL MODIFIED OUT_DIR [--texture-check] [--vowel-check]
 */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { VoiceEngine } from '../../cross-platform/out/main/engine.js';
import { defaultSettings } from '../../cross-platform/out/core/settings.js';
import { integratedLUFS } from '../../cross-platform/out/core/loudness.js';
import { writeWav } from '../../cross-platform/out/main/audio.js';

const require = createRequire(new URL('../../cross-platform/package.json', import.meta.url));
const ort = require('onnxruntime-node');
const [sourcePath, modifiedPath, outputPath] = process.argv.slice(2).map(p => resolve(p));
const vowelCheck = process.argv.includes('--vowel-check');
const textureCheck = process.argv.includes('--texture-check') || vowelCheck;
assert(sourcePath && modifiedPath && outputPath, 'Expected ORIGINAL MODIFIED OUT_DIR');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const resources = join(root, 'cross-platform/resources');
const profile = VoiceEngine.bundledProfiles(resources)[0];
const engine = await VoiceEngine.open(profile, resources);
const config = JSON.parse(readFileSync(`${sourcePath}.json`, 'utf8'));
const rate = config.audio.sample_rate;
const map = config.phoneme_id_map;
const settings = { ...defaultSettings(), noiseScale: 0, noiseW: 0 };
const options = { intraOpNumThreads: 1, interOpNumThreads: 1 };
const stock = await ort.InferenceSession.create(sourcePath, options);
const experimental = await ort.InferenceSession.create(modifiedPath, options);
const actualFramesName = experimental.outputNames.find(n => n !== 'output' && n !== 'vf_base_frames');
assert(actualFramesName, 'No actual duration output');
const hash = p => createHash('sha256').update(readFileSync(p)).digest('hex');
const manifest = { sourcePath, sourceSHA256: hash(sourcePath), modifiedPath,
  modifiedSHA256: hash(modifiedPath), rate, settings, parity: [], comparisons: [] };

// Explicit mapping for this controlled sentence, not a general word aligner.
// Proven equivalent to the app's own token encoder on every parity case below.
async function encode(text) {
  const { phonemes } = await engine.phonemesFor(text, settings);
  const pad = map['_'] ?? [];
  const ids = [...map['^'], ...pad];
  const slots = [];
  let word = 0;
  for (const symbol of [...phonemes]) {
    const symbolIds = map[symbol];
    if (symbolIds) {
      for (const id of symbolIds) { slots.push({ index: ids.length, symbol, word }); ids.push(id); }
      // VITS blanks can carry substantial speech duration, not just silence.
      // Keep those between-symbol slots in the explicit fixture alignment.
      for (const id of pad) { slots.push({ index: ids.length, symbol: '_', after: symbol, word }); ids.push(id); }
    }
    if (symbol === ' ') word++;
  }
  for (let i = 0; i < settings.trailingPads; i++) ids.push(...pad);
  ids.push(...map['$']);
  assert.deepEqual(ids, engine.phonemeIds(phonemes, settings), 'Token encoding diverged from app');
  return { text, phonemes, ids, slots };
}

async function infer(encoded, factors, noiseScale = 0) {
  const feeds = {
    input: new ort.Tensor('int64', BigInt64Array.from(encoded.ids, BigInt), [1, encoded.ids.length]),
    input_lengths: new ort.Tensor('int64', BigInt64Array.of(BigInt(encoded.ids.length)), [1]),
    scales: new ort.Tensor('float32', Float32Array.from([noiseScale, 1, 0]), [3]),
  };
  if (factors) {
    assert.equal(factors.length, encoded.ids.length);
    assert(factors.every(v => Number.isFinite(v) && v >= 0.5 && v <= 2.5));
    feeds.vf_duration_factors = new ort.Tensor('float32', factors, [1, 1, factors.length]);
  }
  return (factors ? experimental : stock).run(feeds);
}

const sentence = "I didn't say you stole it.";
for (const text of ["Yes.", sentence, "You really thought I was going to make this easy for you?",
  "When you arrive at the old house beside the river, take a moment to notice the windows, the garden, and the quiet path leading all the way down to the water."]) {
  const encoded = await encode(text);
  const original = (await infer(encoded)).output.data;
  const result = await infer(encoded, new Float32Array(encoded.ids.length).fill(1));
  const same = result.output.data;
  assert.equal(same.length, original.length, 'Neutral factors changed frame count');
  let maxError = 0;
  for (let i = 0; i < same.length; i++) maxError = Math.max(maxError, Math.abs(same[i] - original[i]));
  assert(maxError < 1e-5, `Neutral factors changed waveform: ${maxError}`);
  assert.deepEqual(result.vf_base_frames.data, result[actualFramesName].data);
  manifest.parity.push({ text, tokens: encoded.ids.length, samples: same.length, maxError });
  console.log(`neutral parity: ${encoded.ids.length} tokens, max error ${maxError}`);
}

const encoded = await encode(sentence);
const groups = encoded.phonemes.split(' ');
console.log('phoneme groups:', JSON.stringify(groups));
// Guard this particular English fixture: never quietly target a guessed word.
assert.equal(groups.length, 6, 'Fixture requires six phoneme word groups');
assert(/j[əuʊ]/u.test(groups[3]), 'Fourth group must be you');
assert(/st/u.test(groups[4]), 'Fifth group must be stole');
const base = await infer(encoded, new Float32Array(encoded.ids.length).fill(1));
const neutralFactors = new Float32Array(encoded.ids.length).fill(1);
const clips = [{ label: 'Original timing', file: '0-reference.wav', samples: base.output.data,
  factors: neutralFactors, frames: base[actualFramesName].data, noiseScale: 0 }];
const baseFrames = base.vf_base_frames.data;
manifest.baselineAlignment = encoded.slots.map(s => ({ ...s, frames: baseFrames[s.index] }));
for (const [label, word] of [['Lengthen YOU', 3], ['Lengthen STOLE', 4]]) {
  const factors = new Float32Array(encoded.ids.length).fill(1);
  const changed = encoded.slots.filter(s => s.word === word && s.symbol !== ' ' && s.after !== ' ');
  assert(changed.length, 'No target word span found');
  for (const slot of changed) factors[slot.index] = 2.5;
  const result = await infer(encoded, factors);
  assert.deepEqual(result.vf_base_frames.data, baseFrames, 'Underlying duration prediction changed');
  const actualFrames = result[actualFramesName].data;
  let extraFrames = 0;
  for (let i = 0; i < actualFrames.length; i++) {
    if (factors[i] === 1) assert.equal(actualFrames[i], baseFrames[i], 'Untargeted token duration changed');
    else { assert(actualFrames[i] >= baseFrames[i], 'Target duration decreased'); extraFrames += actualFrames[i] - baseFrames[i]; }
  }
  assert(extraFrames * 256 / rate >= 0.15,
    `Target change is too small for this listening experiment: ${extraFrames} frames`);
  assert.equal(result.output.data.length - base.output.data.length, extraFrames * 256,
    'Audio length does not follow the new alignment frames');
  manifest.comparisons.push({ label, text: sentence, phonemes: encoded.phonemes,
    durationFactor: 2.5,
    changed: changed.map(s => ({ ...s, beforeFrames: baseFrames[s.index], afterFrames: actualFrames[s.index] })),
    otherTokenDurationsUnchanged: true, extraSeconds: extraFrames * 256 / rate });
  clips.push({ label, file: word === 3 ? '1-you.wav' : '2-stole.wav', samples: result.output.data,
    factors, frames: actualFrames, noiseScale: 0 });
  console.log(`${label}: +${(extraFrames * 256 / rate).toFixed(3)} seconds, other token durations unchanged`);
}

if (textureCheck) {
  const noiseScale = config.inference.noise_scale;
  assert(Number.isFinite(noiseScale) && noiseScale > 0 && noiseScale <= 1.5);
  // Only acoustic noise changes. Duration noise remains zero, and every
  // rounded alignment duration must equal its earlier zero-noise counterpart.
  for (const c of [...clips]) {
    const result = await infer(encoded, c.factors, noiseScale);
    assert.deepEqual(result.vf_base_frames.data, baseFrames, 'Acoustic noise changed duration prediction');
    assert.deepEqual(result[actualFramesName].data, c.frames, 'Acoustic noise changed alignment');
    assert.equal(result.output.data.length, c.samples.length, 'Acoustic noise changed sample count');
    clips.push({ ...c, file: c.file.replace('.wav', '-texture.wav'),
      label: `${c.label}, model acoustic noise ${noiseScale}`, samples: result.output.data, noiseScale });
  }
  manifest.textureCheck = { noiseScale, durationNoise: 0, identicalAlignmentVerified: true,
    randomSeed: null, limitation: 'One unseeded acoustic noise draw per clip; not a perceptual-quality test.' };
}

if (vowelCheck) {
  assert.equal(groups[4], 'stˈoʊl', 'This experiment only supports the inspected stole fixture');
  const vowels = new Set(['o', 'ʊ']);
  const changed = encoded.slots.filter(s => s.word === 4 &&
    (vowels.has(s.symbol) || (s.symbol === '_' && vowels.has(s.after))));
  assert.equal(changed.length, 4, 'Expected two vowel tokens and their following blanks');
  const protectedSlots = encoded.slots.filter(s => s.word === 4 &&
    !changed.some(c => c.index === s.index));
  assert(['s', 't', 'l'].every(symbol => protectedSlots.some(s => s.symbol === symbol)));
  manifest.vowelCheck = { protectedSlots, comparisons: [],
    limitation: 'Blank-token acoustic boundaries are not independently measured; consonant token durations are protected, not guaranteed identical waveforms.' };
  for (const factor of [1.65, 2]) {
    const factors = new Float32Array(encoded.ids.length).fill(1);
    for (const slot of changed) factors[slot.index] = factor;
    const noiseScale = config.inference.noise_scale;
    const result = await infer(encoded, factors, noiseScale);
    assert.deepEqual(result.vf_base_frames.data, baseFrames);
    const actualFrames = result[actualFramesName].data;
    let extraFrames = 0;
    for (let i = 0; i < actualFrames.length; i++) {
      if (factors[i] === 1) assert.equal(actualFrames[i], baseFrames[i], 'Protected token duration changed');
      else { assert(actualFrames[i] >= baseFrames[i]); extraFrames += actualFrames[i] - baseFrames[i]; }
    }
    const extraSeconds = extraFrames * 256 / rate;
    assert(extraSeconds > 0 && extraSeconds <= 0.15, 'Vowel extension exceeded experiment limit');
    assert.equal(result.output.data.length - base.output.data.length, extraFrames * 256);
    const file = `stole-vowel-${factor}.wav`;
    clips.push({ label: `STOLE vowel extension ${factor}`, file, samples: result.output.data,
      factors, frames: actualFrames, noiseScale });
    manifest.vowelCheck.comparisons.push({ file, factor, extraSeconds,
      protectedTokenDurationsUnchanged: true,
      changed: changed.map(s => ({ ...s, beforeFrames: baseFrames[s.index], afterFrames: actualFrames[s.index] })) });
    console.log(`STOLE vowel ${factor}: +${extraSeconds.toFixed(3)} seconds; consonant token durations unchanged`);
  }
}

const peak = samples => samples.reduce((a, b) => Math.max(a, Math.abs(b)), 0);
const levels = clips.map(c => integratedLUFS(c.samples, rate));
assert(levels.every(Number.isFinite));
assert(clips.every(c => c.samples.every(Number.isFinite)));
const targetLUFS = Math.min(-24, ...levels, ...clips.map((c, i) => levels[i] - 3 - 20 * Math.log10(peak(c.samples))));
mkdirSync(outputPath, { recursive: true });
manifest.clips = clips.map((c, i) => {
  const gain = Math.pow(10, (targetLUFS - levels[i]) / 20);
  const audio = c.samples.map(v => v * gain);
  assert(peak(audio) < 1);
  const file = c.file;
  writeFileSync(join(outputPath, file), writeWav(audio, rate, 16), { flag: 'wx' });
  return { label: c.label, file, noiseScale: c.noiseScale, seconds: audio.length / rate, gain,
    lufs: integratedLUFS(audio, rate), samplePeakDBFS: 20 * Math.log10(peak(audio)) };
});
manifest.limitations = ['Duration control only; no pitch or emotion conditioning.',
  'Parity tests use zero noise; see per-clip noiseScale for acoustic texture checks. Duration noise remains zero.',
  'Naturalness and glitchiness require listening; levels do not certify audio quality.',
  'Word-to-phoneme targeting is verified only for the fixed six-word fixture.',
  'Sample peak is not a true-peak or perceptual-quality measurement.'];
assert.equal(hash(sourcePath), manifest.sourceSHA256, 'Source file changed');
writeFileSync(join(outputPath, 'manifest.json'), JSON.stringify(manifest, null, 2), { flag: 'wx' });
await stock.release(); await experimental.release();
console.log('Results:', outputPath);
