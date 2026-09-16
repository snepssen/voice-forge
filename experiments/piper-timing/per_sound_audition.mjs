/**
 * Does weighting a stretch per sound fix what the uniform stretch got wrong?
 *
 * The earlier whole-span experiment stretched every token of "stole" by 2.5 and
 * was rejected: "ssttoollee". The vowel-only variant at the same magnitude was
 * preferred. This runs that distinction as a rule rather than a hand-picked
 * span — the app's own phoneme class map decides how much of a direction each
 * sound receives — and puts the rejected uniform version beside it so the
 * comparison is audible rather than argued.
 *
 * Nothing here is an app change. The experimental graph has an extra required
 * input and must not be installed in the stock app.
 *
 * Usage: node experiments/piper-timing/per_sound_audition.mjs MODIFIED OUT_DIR
 */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { VoiceEngine } from '../../cross-platform/out/main/engine.js';
import { defaultSettings } from '../../cross-platform/out/core/settings.js';
import { durationFactors, accentEnvelope, addedSeconds, wordPhonemes, nucleus, fullAccentDB }
  from '../../cross-platform/out/core/timingPlan.js';
import { phonemeClass, susceptibility } from '../../cross-platform/out/core/phonology.js';
import { writeWav } from '../../cross-platform/out/main/audio.js';

const require = createRequire(new URL('../../cross-platform/package.json', import.meta.url));
const ort = require('onnxruntime-node');
const [modifiedPath, outputPath] = process.argv.slice(2).map(p => p && resolve(p));
assert(modifiedPath && outputPath, 'Expected MODIFIED OUT_DIR');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const resources = join(root, 'cross-platform/resources');
const profile = VoiceEngine.bundledProfiles(resources)[0];
const engine = await VoiceEngine.open(profile, resources);
const stockPath = profile.modelPath ?? join(resources, 'voices', `${profile.name}.onnx`);
const config = JSON.parse(readFileSync(`${stockPath}.json`, 'utf8'));
const rate = config.audio.sample_rate;
const hop = 256;

const options = { intraOpNumThreads: 1, interOpNumThreads: 1 };
const stock = await ort.InferenceSession.create(stockPath, options);
const experimental = await ort.InferenceSession.create(modifiedPath, options);
const framesName = experimental.outputNames.find(n => n !== 'output' && n !== 'vf_base_frames');
assert(framesName, 'No actual duration output on the experimental graph');
const sha = p => createHash('sha256').update(readFileSync(p)).digest('hex');

// Duration noise stays at zero throughout so that alignment is deterministic
// and two clips differ by the direction rather than by a different draw.
const base = { ...defaultSettings(), noiseW: 0 };
const silent = { ...base, noiseScale: 0 };
const textured = { ...base, noiseScale: config.inference.noise_scale };

async function run(session, ids, factors, noiseScale) {
  const feeds = {
    input: new ort.Tensor('int64', BigInt64Array.from(ids, BigInt), [1, ids.length]),
    input_lengths: new ort.Tensor('int64', BigInt64Array.of(BigInt(ids.length)), [1]),
    scales: new ort.Tensor('float32', Float32Array.from([noiseScale, 1, 0]), [3]),
  };
  if (factors) {
    assert.equal(factors.length, ids.length, 'A factor vector must cover every token');
    assert(factors.every(v => Number.isFinite(v) && v >= 0.5 && v <= 2.5), 'Factor out of range');
    feeds.vf_duration_factors = new ort.Tensor('float32', factors, [1, 1, factors.length]);
  }
  return session.run(feeds);
}

const fixtures = [
  { text: "I didn't say you stole it.", word: 4, expect: /^st/u, stretch: 2, accent: 0.45 },
  { text: 'The boat goes slowly.', word: 3, expect: /^sl/u, stretch: 2, accent: 0.45 },
  { text: 'You really thought I was going to make this easy for you?',
    word: 1, expect: /^ɹ/u, stretch: 1.8, accent: 0.5 },
  { text: 'She was absolutely furious.', word: 3, expect: /^fj/u, stretch: 1.9, accent: 0.6 },
];

mkdirSync(outputPath, { recursive: true });
const manifest = {
  stockPath, stockSHA256: sha(stockPath), modifiedPath, modifiedSHA256: sha(modifiedPath),
  rate, hop, susceptibility, note: 'Signal checks only. Delivery is a listening question.',
  parity: [], sentences: [],
};
const page = [];
const inline = new Map();

for (const fixture of fixtures) {
  const { phonemes } = await engine.phonemesFor(fixture.text, silent);
  const layout = engine.tokenLayout(phonemes, silent);
  const ids = layout.ids;
  assert.deepEqual(ids, engine.phonemeIds(phonemes, silent), 'Layout diverged from the app encoder');

  const target = wordPhonemes(layout, fixture.word);
  assert(fixture.expect.test(target), `Word ${fixture.word} is ${target}, not the intended one`);

  // 1. A vector of ones must reproduce the stock model exactly, or every
  //    comparison below is measuring the patch rather than the direction.
  const ones = new Float32Array(ids.length).fill(1);
  const dry = await run(stock, ids, null, 0);
  const neutral = await run(experimental, ids, ones, 0);
  let maxError = 0;
  for (let i = 0; i < dry.output.data.length; i++) {
    maxError = Math.max(maxError, Math.abs(dry.output.data[i] - neutral.output.data[i]));
  }
  assert.equal(neutral.output.data.length, dry.output.data.length, 'Neutral factors moved the frame count');
  assert(maxError < 1e-5, `Neutral factors changed the waveform: ${maxError}`);
  manifest.parity.push({ text: fixture.text, tokens: ids.length, maxError });

  const baseFrames = neutral.vf_base_frames.data;
  const direction = [{ word: fixture.word, stretch: fixture.stretch, accent: 0, accentDB: 0 }];
  // The lift is the open question, so it is the only thing that varies down
  // this ladder: same stretch, same nucleus hold, more level.
  const levels = [fullAccentDB];
  const accented = level => [{ word: fixture.word, stretch: fixture.stretch,
                              accent: fixture.accent, accentDB: level }];

  // The rejected control: every token of the word, including its stops.
  const uniform = new Float32Array(ids.length).fill(1);
  for (const slot of layout.slots) {
    if (slot.word === fixture.word && (slot.kind === 'symbol' || slot.kind === 'blank')) {
      uniform[slot.index] = fixture.stretch;
    }
  }
  const weighted = durationFactors(layout, direction);

  const takes = [
    { label: 'Dry — no direction', factors: ones },
    { label: `Uniform ×${fixture.stretch} (the rejected kind)`, factors: uniform },
    { label: `Per sound ×${fixture.stretch}, no accent`, factors: weighted },
    ...levels.map(level => ({
      label: `Accent +${level} dB`,
      factors: durationFactors(layout, accented(level)),
      envelope: accented(level),
    })),
  ];

  const entry = { text: fixture.text, phonemes, word: fixture.word, target,
                  nucleus: nucleus(layout, fixture.word).filter(s => s.kind === 'symbol')
                    .map(s => s.symbol).join(''), takes: [] };

  // Acoustic noise is unseeded, so two inference calls differ by their draw as
  // well as by their direction. The accent ladder asks for the same timing at
  // three levels, so it must come from one draw: otherwise a listener judging
  // a 1.5 dB step is also hearing a different noise field, and the sample peak
  // stops being evidence about the lift at all.
  const drawn = new Map();
  const renderOnce = async factors => {
    const key = factors.join(',');
    if (!drawn.has(key)) drawn.set(key, await run(experimental, ids, factors, textured.noiseScale));
    return drawn.get(key);
  };

  for (const take of takes) {
    const result = await renderOnce(take.factors);
    const frames = result[framesName].data;
    assert.deepEqual(result.vf_base_frames.data, baseFrames, 'The duration prediction itself moved');

    // Nothing outside the directed word may move, and inside it, no stop may.
    let heldStops = 0;
    for (const slot of layout.slots) {
      const untouched = take.factors[slot.index] === 1;
      if (untouched) {
        assert.equal(frames[slot.index], baseFrames[slot.index],
          `An undirected token changed duration at ${slot.index}`);
      }
      if (slot.word === fixture.word && susceptibility[phonemeClass(slot.symbol)] === 0
          && take.factors !== uniform) {
        assert.equal(frames[slot.index], baseFrames[slot.index],
          `A ${phonemeClass(slot.symbol)} was held at ${slot.index}`);
        heldStops++;
      }
    }

    let samples = Float32Array.from(result.output.data);
    assert.equal(samples.length % hop, 0, 'Audio length is not a whole number of frames');
    if (take.envelope) {
      const gain = accentEnvelope(layout, take.envelope, frames, samples.length, hop);
      samples = samples.map((v, i) => v * gain[i]);
    }
    let peak = 0; for (const v of samples) peak = Math.max(peak, Math.abs(v));
    assert(peak < 1, `Clip reached the sample ceiling: ${peak}`);

    // The sentence index keeps two fixtures that direct the same word number
    // from writing over each other's takes.
    const file = `s${manifest.sentences.length}-${entry.takes.length}-` +
      `${take.label.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}.wav`;
    const wav = writeWav(samples, rate, 16);
    writeFileSync(join(outputPath, file), wav);
    // The page also carries the audio inline, so it plays wherever it is
    // opened rather than only beside the directory it was written into.
    inline.set(file, `data:audio/wav;base64,${Buffer.from(wav).toString('base64')}`);
    entry.takes.push({ label: take.label, file,
      seconds: +(samples.length / rate).toFixed(4),
      addedSeconds: +addedSeconds(baseFrames, frames, hop, rate).toFixed(4),
      peakDBFS: +(20 * Math.log10(peak)).toFixed(2),
      protectedTokens: heldStops });
    console.log(`  ${fixture.text.slice(0, 28).padEnd(30)} ${take.label.padEnd(36)} ` +
      `+${addedSeconds(baseFrames, frames, hop, rate).toFixed(3)}s`);
  }
  manifest.sentences.push(entry);
  page.push(`<section><h2>${entry.text}</h2>` +
    `<p class="ipa">${phonemes} &nbsp;·&nbsp; holding <b>${target}</b>, nucleus <b>${entry.nucleus}</b></p>` +
    entry.takes.map(t => `<div class="take"><span>${t.label}</span>` +
      `<audio controls preload="metadata" src="${inline.get(t.file)}"></audio>` +
      `<span class="n">+${t.addedSeconds.toFixed(3)}s</span></div>`).join('') + '</section>');
}

writeFileSync(join(outputPath, 'manifest.json'), JSON.stringify(manifest, null, 2));
writeFileSync(join(outputPath, 'index.html'), `<!doctype html><meta charset="utf-8">
<title>Per-sound timing audition</title><style>
body{font:15px/1.6 -apple-system,system-ui,sans-serif;max-width:52rem;margin:3rem auto;padding:0 1.5rem;
background:#1d1e19;color:#f8f8f2}h1{font-size:1.4rem}h2{font-size:1.05rem;margin:2rem 0 .3rem;color:#a6e22e}
.ipa{color:#8d8d86;font-size:.85rem;margin:.2rem 0 .8rem}b{color:#f8f8f2}
.take{display:flex;align-items:center;gap:.9rem;margin:.35rem 0}
.take span:first-child{flex:0 0 17rem;font-size:.85rem}.n{color:#8d8d86;font-size:.8rem}
audio{height:32px;flex:1}p.note{color:#8d8d86;font-size:.85rem}</style>
<h1>Per-sound timing audition</h1>
<p class="note">Each group holds one word. The uniform take stretches every token of
it, stops included — the kind that was rejected as “ssttoollee”. The per-sound take
asks for the same amount but gives each sound only as much as its class can take, so
the stops keep their exact predicted duration. The last take adds an accent: more
hold on the stressed vowel alone, and a level lift shaped around that vowel rather
than across the word &mdash; full value over the nucleus, ramped either side, so the
loudest moment is where the accent actually is, at the settled +${fullAccentDB}&nbsp;dB.
No pitch is shifted anywhere.</p>
${page.join('\n')}
<p class="note">Acoustic noise is the model's own ${textured.noiseScale}; duration noise is zero, so
timing is deterministic and one take differs from another by the direction. Signal
checks passed; whether it is <i>delivery</i> is the listening question.</p>`);

console.log(`\nneutral parity: max error ${Math.max(...manifest.parity.map(p => p.maxError)).toExponential(2)}`);
console.log(`open ${join(outputPath, 'index.html')}`);
