/** Controlled listening fixture. Run with npm run audition.
 * Measurements validate signal properties; only a listener can judge delivery.
 * Each EQ comparison reuses one recording. Cadence comparisons disable both
 * Piper noise scales and verify that the baseline repeats sample-for-sample.
 */
import { mkdtempSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { VoiceEngine } from "../main/engine.js";
import { writeWav } from "../main/audio.js";
import { defaultSettings } from "../core/settings.js";
import { applyExpression, expressionPresets, neutralExpression, toneFor } from "../core/expression.js";
import { integratedLUFS } from "../core/loudness.js";

const resources = join(process.cwd(), "resources");
const profile = VoiceEngine.bundledProfiles(resources)[0];
if (!profile) throw new Error("No bundled Piper voice found");
const engine = await VoiceEngine.open(profile, resources);
const rate = engine.sampleRate;
const directory = mkdtempSync(join(tmpdir(), "voice-forge-listening-"));
const neutral = toneFor(neutralExpression());
const line = "I didn't say you stole my idea; I said you made it sound much more interesting.";
const settings = defaultSettings();
const controlled = { ...settings, noiseScale: 0, noiseW: 0 };
const recording = await engine.renderSentence(line, settings);
const control = await engine.renderSentence(line, controlled);
const repeat = await engine.renderSentence(line, controlled);
if (control.length !== repeat.length || !control.every((v, i) => v === repeat[i])) {
  throw new Error("Piper baseline is not repeatable; cadence comparisons would be confounded.");
}
const hash = (samples: Float32Array) => createHash("sha256")
  .update(Buffer.from(samples.buffer, samples.byteOffset, samples.byteLength)).digest("hex");
const samplePeak = (samples: Float32Array) => samples.reduce((peak, v) => Math.max(peak, Math.abs(v)), 0);
type Clip = { label: string; text: string; samples: Float32Array };

const toneClips: Clip[] = expressionPresets.map(preset => ({
  label: preset === "neutral" ? "Unprocessed reference" : `${preset} — EQ only`, text: line,
  samples: applyExpression(recording, neutral,
    toneFor({ preset, intensity: 1, transitionSeconds: 0 }), 0, rate),
}));
if (!toneClips[0]!.samples.every((v, i) => v === recording[i])) throw new Error("Neutral changed the recording");
const cadenceClips: Clip[] = [{ label: "Plain reference", text: line, samples: control }];
for (const [label, text] of [
  ["Focus on YOU", "I didn't say *you* stole my idea; I said you made it sound much more interesting."],
  ["Focus on STOLE", "I didn't say you *stole* my idea; I said you made it sound much more interesting."],
  ["Pause before the reveal", "I didn't say you stole my idea; I said [[beat:long]] you made it sound much more interesting."],
]) cadenceClips.push({ label: label!, text: text!, samples: await engine.renderSentence(text!, controlled) });

const escapeHTML = (value: string) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;").replaceAll('"', "&quot;");
const manifest: Record<string, unknown> = {
  voice: profile.name, sampleRate: rate, settings, controlledSettings: controlled,
  sourceSHA256: hash(recording), repeatableCadence: true,
  limitations: ["EQ changes tone, not the underlying acting.",
    "Zero noise makes cadence comparisons repeatable but differs from ordinary synthesis.",
    "Extra PAD tokens are a timing experiment; their duration and naturalness are voice-dependent.",
    "The ceiling here measures sample peaks, not intersample peaks or perceived distortion."],
};

function section(id: string, title: string, description: string, clips: Clip[]): string {
  const levels = clips.map(c => integratedLUFS(c.samples, rate));
  if (clips.some(c => !c.samples.length || !c.samples.every(Number.isFinite))
      || levels.some(v => !Number.isFinite(v))) throw new Error("Invalid audio or loudness");
  // One common target per group. Use scalar gain only; never clip/compress.
  // Cap by the quietest source and each clip's sample-peak headroom.
  const target = Math.min(-24, ...levels, ...clips.map((c, i) =>
    levels[i]! - 3 - 20 * Math.log10(samplePeak(c.samples))));
  const entries = clips.map((clip, i) => {
    const gainDB = target - levels[i]!;
    const samples = clip.samples.map(v => v * Math.pow(10, gainDB / 20));
    if (samplePeak(samples) >= 1) throw new Error("Audition would clip");
    const file = `${id}-${i}.wav`;
    writeFileSync(join(directory, file), writeWav(samples, rate, 16));
    return { label: clip.label, text: clip.text, file, sourceSHA256: hash(clip.samples),
      seconds: samples.length / rate, gainDB, lufs: integratedLUFS(samples, rate),
      samplePeakDBFS: 20 * Math.log10(samplePeak(samples)) };
  });
  manifest[id] = { targetLUFS: target, clips: entries };
  console.log(`${id}: ${clips.length} clips, level-matched at ${target.toFixed(1)} LUFS`);
  return `<section><h2>${title}</h2><p>${description}</p>${entries.map(c =>
    `<article><h3>${escapeHTML(c.label)}</h3><p>${escapeHTML(c.text)}</p>
     <audio controls preload="none" src="${c.file}"></audio>
     <small>${c.seconds.toFixed(2)} s · ${c.lufs.toFixed(1)} LUFS · ${c.samplePeakDBFS.toFixed(1)} dBFS sample peak</small></article>`
  ).join("")}</section>`;
}
const toneHTML = section("tone", "Same recording, different EQ",
  "Every clip starts with the exact same Piper recording. They have matched loudness. Listen for changes in colour, clarity and unwanted roughness.", toneClips);
const cadenceHTML = section("cadence", "Words and timing",
  "Piper's two noise scales are zero for these comparisons. No EQ is applied. Listen for the intended emphasis, intact words, and whether the pause sounds natural. A longer clip alone does not prove better cadence.", cadenceClips);
writeFileSync(join(directory, "manifest.json"), JSON.stringify(manifest, null, 2));
writeFileSync(join(directory, "index.html"), `<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Voice Forge listening bench</title>
<style>body{font:17px/1.5 system-ui;max-width:850px;margin:3rem auto;padding:0 1.5rem;color:#222;background:#faf8f3}
article{padding:1rem 1.4rem;margin:1rem 0;background:white;border:1px solid #ddd;border-radius:10px}
h1,h2,h3{line-height:1.2}small{display:block;color:#555}audio{width:100%;margin:.5rem 0}section{margin:3rem 0}</style>
<h1>Voice Forge listening bench</h1><p>Voice: ${escapeHTML(profile.name)}. Experimental comparisons, not a claim of emotional acting.</p>
${toneHTML}${cadenceHTML}<p><a href="manifest.json">Recording provenance and measurements</a></p></html>`);
console.log(`Listening page: ${join(directory, "index.html")}`);
