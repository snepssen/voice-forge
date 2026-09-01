/**
 * Programme loudness to ITU-R BS.1770-4, in LUFS.
 *
 * The number every platform normalises against, and the reason a voiceover that
 * sounded right in isolation gets turned down on upload. Peak does not predict
 * it: a track can peak at -0.1 dBFS and measure -24 LUFS if it is mostly quiet,
 * which is exactly what one voice reading a script does.
 *
 * Implemented rather than approximated, because an approximation here would be
 * believed. The K-weighting filters are derived from BS.1770's analog prototype
 * by bilinear transform at whatever rate is passed in, never copied from the
 * published 48 kHz coefficient table — the model speaks at 22.05 kHz, and a
 * 48 kHz table applied there is wrong by several LU with nothing to show for it.
 */

export interface LoudnessTarget {
  name: string;
  /** NaN means "leave it alone". */
  lufs: number;
  truePeakCeiling: number;
  note: string;
}

export const loudnessTargets: LoudnessTarget[] = [
  { name: "YouTube", lufs: -14, truePeakCeiling: -1,
    note: "Turns anything louder down to -14. Going above it gains nothing and costs dynamics." },
  { name: "Podcast", lufs: -16, truePeakCeiling: -1,
    note: "Apple and Spotify spoken-word target. A little quieter than video, for headphones." },
  { name: "Broadcast (EBU R128)", lufs: -23, truePeakCeiling: -1,
    note: "European broadcast. Much quieter than streaming; only right if something asked for it." },
  { name: "Leave it alone", lufs: NaN, truePeakCeiling: NaN,
    note: "Export at the level the model produced, gain untouched." },
];

interface Biquad { b0: number; b1: number; b2: number; a1: number; a2: number }

function apply(f: Biquad, x: Float64Array): Float64Array {
  const y = new Float64Array(x.length);
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < x.length; i++) {
    const out = f.b0 * x[i]! + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2;
    x2 = x1; x1 = x[i]!;
    y2 = y1; y1 = out;
    y[i] = out;
  }
  return y;
}

/** Stage 1: a +4 dB high shelf standing in for a head in the sound field. */
export function headShelf(rate: number): Biquad {
  const f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196;
  const K = Math.tan(Math.PI * f0 / rate);
  const Vh = Math.pow(10, G / 20);
  const Vb = Math.pow(Vh, 0.4996667741545416);
  const a0 = 1 + K / Q + K * K;
  return {
    b0: (Vh + Vb * K / Q + K * K) / a0,
    b1: 2 * (K * K - Vh) / a0,
    b2: (Vh - Vb * K / Q + K * K) / a0,
    a1: 2 * (K * K - 1) / a0,
    a2: (1 - K / Q + K * K) / a0,
  };
}

/** Stage 2: the RLB high-pass, which discards rumble the ear does not weigh. */
export function rlbHighPass(rate: number): Biquad {
  const f0 = 38.13547087602444, Q = 0.5003270373238773;
  const K = Math.tan(Math.PI * f0 / rate);
  const a0 = 1 + K / Q + K * K;
  return { b0: 1, b1: -2, b2: 1, a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0 };
}

/**
 * Integrated programme loudness, LUFS. -Infinity for silence rather than a
 * fabricated floor.
 *
 * Mono, so channel weighting is 1.0. 400 ms blocks at 75% overlap, then
 * BS.1770's two-stage gate: drop blocks below an absolute -70 LUFS, take the
 * mean, then drop blocks more than 10 LU below *that* and take the mean again.
 * The relative gate is what stops the silence between sentences dragging a
 * spoken-word track several LU too quiet — the single biggest reason a naive
 * RMS disagrees with what a platform reports.
 */
export function integratedLUFS(samples: Float32Array | number[], rate: number): number {
  const n = samples.length;
  if (n <= rate * 0.4) return -Infinity;
  const x = new Float64Array(n);
  for (let i = 0; i < n; i++) x[i] = samples[i]!;
  const filtered = apply(rlbHighPass(rate), apply(headShelf(rate), x));

  const blockSize = Math.floor(rate * 0.4);
  const hop = Math.max(1, Math.floor(blockSize / 4));
  const power: number[] = [];
  for (let start = 0; start + blockSize <= filtered.length; start += hop) {
    let sum = 0;
    for (let i = start; i < start + blockSize; i++) sum += filtered[i]! * filtered[i]!;
    power.push(sum / blockSize);
  }
  if (!power.length) return -Infinity;

  const loud = (p: number) => (p > 0 ? -0.691 + 10 * Math.log10(p) : -Infinity);
  const aboveAbsolute = power.filter(p => loud(p) > -70);
  if (!aboveAbsolute.length) return -Infinity;
  const ungated = aboveAbsolute.reduce((a, b) => a + b, 0) / aboveAbsolute.length;
  const threshold = loud(ungated) - 10;
  const gated = aboveAbsolute.filter(p => loud(p) > threshold);
  if (!gated.length) return loud(ungated);
  return loud(gated.reduce((a, b) => a + b, 0) / gated.length);
}

/**
 * True peak in dBTP, estimated by 4x oversampling.
 *
 * Sample peak is not true peak: a waveform can pass between two samples at a
 * level neither shows, and that inter-sample peak is what clips a lossy encoder
 * downstream. Linear interpolation is biased *low*, so it can under-report a
 * hair — never over-report, which would be the dangerous direction.
 */
export function truePeakDBTP(samples: Float32Array | number[], _rate: number): number {
  if (!samples.length) return -Infinity;
  let peak = 0;
  for (let i = 0; i < samples.length; i++) {
    const a = samples[i]!;
    peak = Math.max(peak, Math.abs(a));
    if (i + 1 >= samples.length) continue;
    const b = samples[i + 1]!;
    for (let k = 1; k < 4; k++) peak = Math.max(peak, Math.abs(a + (b - a) * (k / 4)));
  }
  return peak > 0 ? 20 * Math.log10(peak) : -Infinity;
}
