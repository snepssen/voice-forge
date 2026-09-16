/** Recover complete model timing for an existing approved audition, without a new listening take.
 * node pitch_alignment.mjs MANIFEST OUTPUT_JSON
 */
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, dirname, join } from 'node:path';
const require = createRequire(new URL('../../cross-platform/package.json', import.meta.url));
const ort = require('onnxruntime-node');
const [manifestPath, outputPath] = process.argv.slice(2).map(p => resolve(p));
assert(manifestPath && outputPath);
const m = JSON.parse(readFileSync(manifestPath));
const sha = p => createHash('sha256').update(readFileSync(p)).digest('hex');
assert.equal(sha(m.modifiedPath), m.modifiedSHA256);
const config = JSON.parse(readFileSync(m.sourcePath + '.json'));
const map = config.phoneme_id_map;
const phonemes = m.comparisons[0].phonemes;
assert.equal(phonemes, 'aɪ dˈɪdnt sˈeɪ juː stˈoʊl ɪt');
const ids = [...map['^'], ...map['_']];
for (const symbol of phonemes) if (map[symbol]) ids.push(...map[symbol], ...map['_']);
for (let i = 0; i < m.settings.trailingPads; i++) ids.push(...map['_']);
ids.push(...map['$']);
const session = await ort.InferenceSession.create(m.modifiedPath, { intraOpNumThreads: 1, interOpNumThreads: 1 });
const result = await session.run({
  input: new ort.Tensor('int64', BigInt64Array.from(ids, BigInt), [1, ids.length]),
  input_lengths: new ort.Tensor('int64', BigInt64Array.of(BigInt(ids.length)), [1]),
  scales: new ort.Tensor('float32', Float32Array.of(0, 1, 0), [3]),
  vf_duration_factors: new ort.Tensor('float32', new Float32Array(ids.length).fill(1), [1, 1, ids.length]),
});
const frames = Array.from(result.vf_base_frames.data);
for (const s of m.baselineAlignment) assert.equal(frames[s.index], s.frames);
const variant = m.vowelCheck.comparisons.find(c => c.factor === 2);
assert(variant);
for (const s of variant.changed) { assert.equal(frames[s.index], s.beforeFrames); frames[s.index] = s.afterFrames; }
const clip = m.clips.find(c => c.file === variant.file);
const audioPath = join(dirname(manifestPath), clip.file);
let cursor = 0;
const tokens = frames.map((count, index) => {
  const start = cursor; cursor += count * 256;
  return { ...m.baselineAlignment.find(s => s.index === index), index, frames: count,
    startSample: start, endSample: cursor, start: start / m.rate, end: cursor / m.rate };
});
assert.equal(cursor, Math.round(clip.seconds * m.rate));
const data = { sourceAudio: audioPath, sourceSHA256: sha(audioPath), rate: m.rate,
  sampleCount: cursor, tokens,
  limitation: 'Model alignment boundaries, not independently measured acoustic word boundaries.' };
writeFileSync(outputPath, JSON.stringify(data, null, 2), { flag: 'wx' });
console.log(JSON.stringify(tokens.filter(s => s.word >= 4), null, 2));
await session.release();
