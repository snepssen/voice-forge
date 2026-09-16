import type { SynthesisSettings } from "./settings.js";
import { defaultProsody, type ProsodySettings } from "./prosody.js";

export const expressionPresets = ["neutral", "happy", "playful", "intimate", "flirty", "angry"] as const;
export type ExpressionPreset = typeof expressionPresets[number];

export interface SentenceExpression {
  preset: ExpressionPreset;
  /** Zero is neutral; one is the preset as designed. */
  intensity: number;
  /** Time spent moving from the preceding sentence's tone into this one. */
  transitionSeconds: number;
}

export interface ExpressionTone {
  lowShelfDB: number;
  presenceDB: number;
  highShelfDB: number;
  outputDB: number;
}

interface ExpressionRecipe extends ExpressionTone {
  /** Global pace. Only values that clear the graph's per-token rounding are
   * worth setting: below about ten percent nothing moves at all. */
  paceFactor: number;
  /** How this expression reads — where the weight falls, and how hard. */
  prosody: ProsodySettings;
}

export const neutralExpression = (): SentenceExpression =>
  ({ preset: "neutral", intensity: 1, transitionSeconds: 0.18 });

export const expressionNames: Record<ExpressionPreset, string> = {
  neutral: "Neutral", happy: "Happy", playful: "Playful",
  intimate: "Intimate", flirty: "Flirty", angry: "Angry",
};

export const expressionNotes: Record<ExpressionPreset, string> = {
  neutral: "The reading the text asks for, with no colour on top.",
  happy: "Quicker, brighter, and more of the sentence kept lit.",
  playful: "The unevenest of them: weak words crushed, strong ones sprung.",
  intimate: "Slow, close, and settled. Vowels held well past the point.",
  flirty: "Unhurried, warm, and drawn out at the ends of phrases.",
  angry: "Clipped and driven. Everything unstressed gets out of the way.",
};

/**
 * Each expression is a different *reading*, not a filter over the same one.
 *
 * The earlier recipes moved pace by a few percent, nudged the two noise scales,
 * and applied a shelf or two of EQ. None of it survived contact: the pace
 * change was rounded away by the graph on 98% of tokens, the noise scales only
 * redrew the dice, and broadband EQ reads to the ear as level rather than as
 * character — which is exactly what it sounded like. What is left here is the
 * timing layer, where a direction is big enough to exist, plus a little tint.
 */
const recipes: Record<ExpressionPreset, ExpressionRecipe> = {
  neutral: {
    paceFactor: 1, lowShelfDB: 0, presenceDB: 0, highShelfDB: 0, outputDB: 0,
    prosody: defaultProsody(),
  },
  happy: {
    paceFactor: 0.93, lowShelfDB: -1.5, presenceDB: 1.5, highShelfDB: 2.5, outputDB: 0,
    // More of the sentence stays lit: a repeat steps back less, and the point
    // is made hard.
    prosody: { focus: 1, phraseFinal: 0.1, deaccentRepeats: 0.25, contrast: 0.5,
               nucleusHold: 0.1, accentDB: 6, lift: 0.6 },
  },
  playful: {
    paceFactor: 0.97, lowShelfDB: -1, presenceDB: 2, highShelfDB: 2, outputDB: 0,
    // The widest gap between the words that matter and the ones that do not.
    prosody: { focus: 0.9, phraseFinal: 0.2, deaccentRepeats: 0.5, contrast: 1,
               nucleusHold: 0.35, accentDB: 5.5, lift: 0.7 },
  },
  intimate: {
    paceFactor: 1.12, lowShelfDB: 2.5, presenceDB: -1.5, highShelfDB: -2.5, outputDB: 0,
    // Held rather than hit: long nuclei, long settling, almost no crushing.
    prosody: { focus: 0.45, phraseFinal: 1, deaccentRepeats: 0.7, contrast: 0.05,
               nucleusHold: 0.6, accentDB: 2.5, lift: -0.6 },
  },
  flirty: {
    paceFactor: 1.1, lowShelfDB: 1.5, presenceDB: 0.8, highShelfDB: 1, outputDB: 0,
    prosody: { focus: 0.55, phraseFinal: 1, deaccentRepeats: 0.6, contrast: 0.1,
               nucleusHold: 0.7, accentDB: 3.5, lift: -0.3 },
  },
  angry: {
    paceFactor: 0.9, lowShelfDB: 1.5, presenceDB: 2.5, highShelfDB: 0.8, outputDB: 0,
    // Clipped: the point is hit hard and short, and nothing is allowed to
    // settle at the end of a phrase.
    prosody: { focus: 1, phraseFinal: 0, deaccentRepeats: 0.3, contrast: 1,
               nucleusHold: 0, accentDB: 6, lift: 1 },
  },
};

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

export function normalizedExpression(e?: Partial<SentenceExpression>): SentenceExpression {
  const preset = expressionPresets.includes(e?.preset as ExpressionPreset)
    ? e!.preset as ExpressionPreset : "neutral";
  return {
    preset,
    intensity: clamp(e?.intensity ?? 1, 0, 1),
    transitionSeconds: clamp(e?.transitionSeconds ?? 0.18, 0, 1),
  };
}

export function toneFor(e: SentenceExpression): ExpressionTone {
  const r = recipes[e.preset];
  const n = clamp(e.intensity, 0, 1);
  return {
    lowShelfDB: r.lowShelfDB * n,
    presenceDB: r.presenceDB * n,
    highShelfDB: r.highShelfDB * n,
    outputDB: r.outputDB * n,
  };
}

export function expressionSettings(base: SynthesisSettings, e: SentenceExpression): SynthesisSettings {
  const r = recipes[e.preset];
  const n = clamp(e.intensity, 0, 1);
  // The noise scales used to move here too. They did not encode anything: both
  // change which draw comes out, so two takes of one preset already differed by
  // more than two presets did.
  return {
    ...base,
    lengthScale: clamp(base.lengthScale * (1 + (r.paceFactor - 1) * n), 0.5, 2),
  };
}

/** How this expression reads, at this intensity. At zero it is the reading the
 * text would have got anyway. */
export function expressionProsody(e: SentenceExpression): ProsodySettings {
  const r = recipes[e.preset];
  const n = clamp(e.intensity, 0, 1);
  const base = defaultProsody();
  const mix = (a: number, b: number) => a + (b - a) * n;
  return {
    focus: mix(base.focus, r.prosody.focus),
    phraseFinal: mix(base.phraseFinal, r.prosody.phraseFinal),
    deaccentRepeats: mix(base.deaccentRepeats, r.prosody.deaccentRepeats),
    contrast: mix(base.contrast, r.prosody.contrast),
    nucleusHold: mix(base.nucleusHold, r.prosody.nucleusHold),
    accentDB: mix(base.accentDB, r.prosody.accentDB),
    lift: mix(base.lift, r.prosody.lift),
  };
}

const isNeutral = (t: ExpressionTone) =>
  t.lowShelfDB === 0 && t.presenceDB === 0 && t.highShelfDB === 0 && t.outputDB === 0;

interface Coefficients { b0: number; b1: number; b2: number; a1: number; a2: number }

class Biquad {
  private x1 = 0; private x2 = 0; private y1 = 0; private y2 = 0;
  constructor(private readonly c: Coefficients) {}
  process(x: number): number {
    const y = this.c.b0 * x + this.c.b1 * this.x1 + this.c.b2 * this.x2
      - this.c.a1 * this.y1 - this.c.a2 * this.y2;
    this.x2 = this.x1; this.x1 = x; this.y2 = this.y1; this.y1 = y;
    return y;
  }
}

const identity = (): Coefficients => ({ b0: 1, b1: 0, b2: 0, a1: 0, a2: 0 });
const normalized = (b0: number, b1: number, b2: number, a0: number, a1: number, a2: number): Coefficients =>
  ({ b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 });

function peak(frequency: number, q: number, gainDB: number, rate: number): Coefficients {
  if (Math.abs(gainDB) <= 0.000001) return identity();
  const a = Math.pow(10, gainDB / 40);
  const w = 2 * Math.PI * frequency / rate;
  const alpha = Math.sin(w) / (2 * q);
  return normalized(1 + alpha * a, -2 * Math.cos(w), 1 - alpha * a,
                    1 + alpha / a, -2 * Math.cos(w), 1 - alpha / a);
}

function shelf(low: boolean, frequency: number, gainDB: number, rate: number): Coefficients {
  if (Math.abs(gainDB) <= 0.000001) return identity();
  const a = Math.pow(10, gainDB / 40);
  const w = 2 * Math.PI * frequency / rate;
  const c = Math.cos(w), alpha = Math.sin(w) / Math.SQRT2, root = 2 * Math.sqrt(a) * alpha;
  if (low) {
    return normalized(
      a * ((a + 1) - (a - 1) * c + root),
      2 * a * ((a - 1) - (a + 1) * c),
      a * ((a + 1) - (a - 1) * c - root),
      (a + 1) + (a - 1) * c + root,
      -2 * ((a - 1) + (a + 1) * c),
      (a + 1) + (a - 1) * c - root);
  }
  return normalized(
    a * ((a + 1) + (a - 1) * c + root),
    -2 * a * ((a - 1) + (a + 1) * c),
    a * ((a + 1) + (a - 1) * c - root),
    (a + 1) - (a - 1) * c + root,
    2 * ((a - 1) - (a + 1) * c),
    (a + 1) - (a - 1) * c - root);
}

class Chain {
  private readonly low: Biquad;
  private readonly presence: Biquad;
  private readonly high: Biquad;
  private readonly gain: number;
  constructor(tone: ExpressionTone, rate: number) {
    this.low = new Biquad(shelf(true, Math.min(180, rate * 0.2), tone.lowShelfDB, rate));
    this.presence = new Biquad(peak(Math.min(1800, rate * 0.35), 0.85, tone.presenceDB, rate));
    this.high = new Biquad(shelf(false, Math.min(4200, rate * 0.42), tone.highShelfDB, rate));
    this.gain = Math.pow(10, tone.outputDB / 20);
  }
  process(x: number): number {
    return this.high.process(this.presence.process(this.low.process(x))) * this.gain;
  }
}

/** Crossfade two stable, linear filter paths instead of interpolating
 * coefficients, which can make a stable biquad briefly unstable. */
export function applyExpression(samples: Float32Array, from: ExpressionTone, to: ExpressionTone,
                                transitionSeconds: number, sampleRate: number): Float32Array {
  if (!samples.length || sampleRate <= 0 || (isNeutral(from) && isNeutral(to))) return samples;
  const a = new Chain(from, sampleRate), b = new Chain(to, sampleRate);
  const transition = Math.min(samples.length, Math.max(0, Math.floor(transitionSeconds * sampleRate)));
  const out = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i++) {
    const av = a.process(samples[i]!), bv = b.process(samples[i]!);
    const linear = transition === 0 ? 1 : Math.min(1, i / transition);
    const mix = linear * linear * (3 - 2 * linear);
    out[i] = av + (bv - av) * mix;
  }
  return out;
}
