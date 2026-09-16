/**
 * What the text gets you with nobody directing it.
 *
 * Every take here is plain prose in and audio out. No markup, no word picked
 * by hand, no number chosen per sentence. The reading comes from three rules
 * over what espeak already encoded — where the phrase is heading, where it
 * settles, and what has already been said — spent through the per-sound layer.
 *
 * The question this is built to answer is not "is this correct" but "is this
 * better than flat, often enough to be on by default". A rule that runs on
 * every sentence without being asked has to be wrong quietly.
 *
 * Usage: node experiments/piper-timing/automatic_audition.mjs MODIFIED OUT_DIR
 */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { VoiceEngine } from '../../cross-platform/out/main/engine.js';
import { defaultSettings } from '../../cross-platform/out/core/settings.js';
import { parseScript } from '../../cross-platform/out/core/script.js';
import { durationFactors, accentEnvelope, addedSeconds }
  from '../../cross-platform/out/core/timingPlan.js';
import { automaticDirections, defaultProsody, prosodicGroups, spokenKeys }
  from '../../cross-platform/out/core/prosody.js';
import { writeWav } from '../../cross-platform/out/main/audio.js';

const require = createRequire(new URL('../../cross-platform/package.json', import.meta.url));
const ort = require('onnxruntime-node');
const [modifiedPath, outputPath] = process.argv.slice(2).map(p => p && resolve(p));
assert(modifiedPath && outputPath, 'Expected MODIFIED OUT_DIR');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const resources = join(root, 'cross-platform/resources');
const profile = VoiceEngine.bundledProfiles(resources)[0];
const engine = await VoiceEngine.open(profile, resources);
const stockPath = profile.modelPath;
const config = JSON.parse(readFileSync(`${stockPath}.json`, 'utf8'));
const rate = config.audio.sample_rate;
const hop = 256;

const options = { intraOpNumThreads: 1, interOpNumThreads: 1 };
const experimental = await ort.InferenceSession.create(modifiedPath, options);
const framesName = experimental.outputNames.find(n => n !== 'output' && n !== 'vf_base_frames');
const sha = p => createHash('sha256').update(readFileSync(p)).digest('hex');

const settings = { ...defaultSettings(), noiseW: 0, noiseScale: config.inference.noise_scale };
const quiet = { ...settings, noiseScale: 0 };

async function run(ids, factors, noiseScale) {
  assert(factors.every(v => Number.isFinite(v) && v >= 0.5 && v <= 2.5), 'Factor out of range');
  return experimental.run({
    input: new ort.Tensor('int64', BigInt64Array.from(ids, BigInt), [1, ids.length]),
    input_lengths: new ort.Tensor('int64', BigInt64Array.of(BigInt(ids.length)), [1]),
    scales: new ort.Tensor('float32', Float32Array.from([noiseScale, 1, 0]), [3]),
    vf_duration_factors: new ort.Tensor('float32', factors, [1, 1, factors.length]),
  });
}

// Ordinary prose, including a paragraph that says a word twice on purpose.
const passages = [
  'The cat sat on the mat in the sun.',
  'She was absolutely furious about the noise from the garden.',
  'When you arrive at the old house beside the river, take a moment to notice the windows, the garden, and the quiet path leading down to the water.',
  'I have told you about the deadline. The deadline has not moved.',
  'It was cold, it was late, and nobody came.',
];

mkdirSync(outputPath, { recursive: true });
const manifest = {
  stockSHA256: sha(stockPath), modifiedSHA256: sha(modifiedPath), rate, hop,
  prosody: defaultProsody(),
  note: 'Signal checks only. Whether this is a better reading is a listening question.',
  passages: [],
};
const page = [];
const inline = new Map();

for (const passage of passages) {
  const script = parseScript(passage);
  const entry = { text: passage, sentences: [], takes: [] };

  // Flat and automatic are assembled sentence by sentence so a paragraph can
  // remember what it has already said, exactly as the app would.
  const spoken = new Set();
  const flatParts = [], directedParts = [];
  let flatSeconds = 0, directedSeconds = 0, totalAdded = 0;

  for (const sentence of script.sentences) {
    const { phonemes } = await engine.phonemesFor(sentence.text, quiet);
    const layout = engine.tokenLayout(phonemes, quiet);
    const ones = new Float32Array(layout.ids.length).fill(1);
    const plan = automaticDirections(layout, defaultProsody(), spoken);
    const factors = durationFactors(layout, plan);

    const flat = await run(layout.ids, ones, settings.noiseScale);
    const directed = await run(layout.ids, factors, settings.noiseScale);
    const baseFrames = flat.vf_base_frames.data;
    const frames = directed[framesName].data;
    assert.deepEqual(directed.vf_base_frames.data, baseFrames,
      'The duration prediction itself moved');
    for (let i = 0; i < factors.length; i++) {
      if (factors[i] === 1) {
        assert.equal(frames[i], baseFrames[i], `An undirected token moved at ${i}`);
      }
    }

    let samples = Float32Array.from(directed.output.data);
    const gain = accentEnvelope(layout, plan, frames, samples.length, hop);
    samples = samples.map((v, i) => v * gain[i]);
    let peak = 0; for (const v of samples) peak = Math.max(peak, Math.abs(v));
    assert(peak < 1, `Clip reached the sample ceiling: ${peak}`);

    const groups = prosodicGroups(layout);
    const directedWords = new Set(plan.map(d => d.word));
    entry.sentences.push({
      text: sentence.text, phonemes,
      reading: groups.map(g => ({
        phonemes: g.phonemes, prominence: g.prominence,
        directed: directedWords.has(g.word),
        accented: plan.some(d => d.word === g.word && d.accentDB > 0),
        given: plan.some(d => d.word === g.word && d.stretch < 1),
      })),
      addedSeconds: +addedSeconds(baseFrames, frames, hop, rate).toFixed(4),
    });
    totalAdded += addedSeconds(baseFrames, frames, hop, rate);

    flatParts.push(Float32Array.from(flat.output.data));
    directedParts.push(samples);
    flatSeconds += flat.output.data.length / rate;
    directedSeconds += samples.length / rate;
    for (const key of spokenKeys(layout)) spoken.add(key);
  }

  const join2 = parts => {
    const gap = Math.round(settings.sentenceGap * rate);
    const total = parts.reduce((n, p) => n + p.length, 0) + gap * (parts.length - 1);
    const out = new Float32Array(total);
    let at = 0;
    parts.forEach((p, i) => { out.set(p, at); at += p.length + (i < parts.length - 1 ? gap : 0); });
    return out;
  };

  for (const [label, samples] of [['Flat — the model as it reads today', join2(flatParts)],
                                  ['Automatic — nobody directed this', join2(directedParts)]]) {
    const file = `p${manifest.passages.length}-${label.startsWith('Flat') ? 'flat' : 'automatic'}.wav`;
    const wav = writeWav(samples, rate, 16);
    writeFileSync(join(outputPath, file), wav);
    inline.set(file, `data:audio/wav;base64,${Buffer.from(wav).toString('base64')}`);
    entry.takes.push({ label, file, seconds: +(samples.length / rate).toFixed(3) });
  }
  entry.addedSeconds = +totalAdded.toFixed(3);
  manifest.passages.push(entry);
  console.log(`  ${passage.slice(0, 44).padEnd(46)} +${totalAdded.toFixed(3)}s ` +
    `(${flatSeconds.toFixed(2)}s -> ${directedSeconds.toFixed(2)}s)`);

  const mark = g => g.accented ? `<b class="acc">${g.phonemes}</b>`
    : g.given ? `<span class="given">${g.phonemes}</span>`
    : g.directed ? `<span class="held">${g.phonemes}</span>` : g.phonemes;
  page.push(`<section><h2>${entry.text}</h2>` +
    entry.sentences.map(s => `<p class="ipa">${s.reading.map(mark).join(' ')}</p>`).join('') +
    entry.takes.map(t => `<div class="take"><span>${t.label}</span>` +
      `<audio controls preload="metadata" src="${inline.get(t.file)}"></audio>` +
      `<span class="n">${t.seconds.toFixed(2)}s</span></div>`).join('') + '</section>');
}

writeFileSync(join(outputPath, 'manifest.json'), JSON.stringify(manifest, null, 2));
writeFileSync(join(outputPath, 'index.html'), `<!doctype html><meta charset="utf-8">
<title>Automatic dynamics</title><style>
body{font:15px/1.6 -apple-system,system-ui,sans-serif;max-width:54rem;margin:3rem auto;padding:0 1.5rem;
background:#1d1e19;color:#f8f8f2}h1{font-size:1.4rem}h2{font-size:1.05rem;margin:2rem 0 .3rem;color:#a6e22e}
.ipa{color:#8d8d86;font-size:.9rem;margin:.2rem 0 .7rem}
b.acc{color:#fd971f;font-weight:600}.given{opacity:.45}.held{color:#66d9ef}
.take{display:flex;align-items:center;gap:.9rem;margin:.35rem 0}
.take span:first-child{flex:0 0 18rem;font-size:.85rem}.n{color:#8d8d86;font-size:.8rem}
audio{height:32px;flex:1}p.note{color:#8d8d86;font-size:.85rem}
.key{font-size:.8rem;color:#8d8d86}</style>
<h1>Automatic dynamics</h1>
<p class="note">Both takes are the same plain sentence typed in. Nothing is marked
up, no word is chosen by hand, no number is set per sentence. The flat take is what
the model reads today. The automatic take is three rules over what espeak already
encoded, spent through the per-sound layer: the point of each phrase gets the
accent, a phrase settles at its boundary, unstressed material gives way, and a word
already said in the paragraph steps back.</p>
<p class="key">In the phonemes below: <b class="acc">orange</b> carries the point ·
<span class="held">blue</span> is held without being accented ·
<span class="given">faded</span> gives way. No pitch is shifted.</p>
${page.join('\n')}
<p class="note">Duration noise is zero so timing is deterministic; acoustic noise is
the model's own ${settings.noiseScale}, one draw per take. Every check passed: the
duration prediction never moved, and no token the rules did not name changed length.
That says the rules did what they said. Whether it is a better <i>reading</i> is
the listening question.</p>`);

console.log(`\nopen ${join(outputPath, 'index.html')}`);
