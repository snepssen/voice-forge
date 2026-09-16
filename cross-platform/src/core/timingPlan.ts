/**
 * Turning a direction about a word into a factor for every sound in it.
 *
 * The model is addressed per token, so per-sound is the primitive here and
 * per-word is a selection over it: "hold this word" means "hold the sounds in
 * this word that can be held, by how much each one can take". Nothing else in
 * the sentence moves, which is checked rather than assumed — the experiment
 * asserts every untargeted token keeps its exact predicted frame count.
 *
 * An accent is not a louder word. It is the stressed nucleus held longer than
 * the rest of its own word, with a small level lift over the same span. Pitch
 * is deliberately absent: every attempt to shift it on this voice was rejected
 * by ear, while the held vowel was the one result that was preferred.
 */

import type { TokenLayout, TokenSlot } from "../main/engine.js";
import { isStress, isVowelish, phonemeClass, primaryStress, susceptibility } from "./phonology.js";

/** What the harness accepts, and well inside where the graph stays sensible. */
export const factorRange = { min: 0.5, max: 2.5 } as const;

/**
 * The level a full accent is given, chosen by ear against +3 and +4.5 on the
 * bundled voice. It is a listening decision, not a derived figure, so it sits
 * here under its own name rather than appearing as a number at a call site —
 * and like every other measurement in this app it belongs to the voice it was
 * chosen on. Worst-case sample peak at this level was -4.11 dBFS, with no
 * limiting, which is the headroom any change to it has to keep.
 */
export const fullAccentDB = 6;

export interface SoundDirection {
  /** Index of the spoken word within this sentence's phoneme stream. */
  word: number;
  /** 1 leaves the word alone. Above 1 holds it, weighted per sound. */
  stretch: number;
  /** Extra hold on the stressed nucleus alone, on top of `stretch`. */
  accent: number;
  /** Level lift across the word, in dB. Small on purpose. */
  accentDB: number;
}

export const neutralDirection = (word: number): SoundDirection =>
  ({ word, stretch: 1, accent: 0, accentDB: 0 });

/**
 * One dial's worth of accent: hold and level move together, because an accent
 * that is only long reads as a drawl and one that is only loud reads as a
 * mistake. Strength runs 0 to 1, and at 1 the level is the settled one.
 */
export const accentedDirection = (word: number, stretch: number,
                                  strength: number): SoundDirection => {
  const s = clamp(strength, 0, 1);
  return { word, stretch, accent: 0.6 * s, accentDB: fullAccentDB * s };
};

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Every token of one spoken word, blanks included, in the model's order. */
export function wordSlots(layout: TokenLayout, word: number): TokenSlot[] {
  return layout.slots.filter(s => s.word === word);
}

/** The word as it would be read aloud in IPA, for showing next to a dial. */
export function wordPhonemes(layout: TokenLayout, word: number): string {
  return wordSlots(layout, word).filter(s => s.kind === "symbol")
    .map(s => s.symbol).join("");
}

/**
 * The vowel run an accent lands on: the one right after the primary stress
 * mark, or — for the many one-syllable words espeak leaves unmarked, `juː`
 * and `ɪt` among them — the word's first vowel run.
 */
export function nucleus(layout: TokenLayout, word: number): TokenSlot[] {
  const slots = wordSlots(layout, word);
  const symbols = slots.filter(s => s.kind === "symbol");
  let start = symbols.findIndex(s => s.symbol === primaryStress);
  if (start >= 0) start += 1;
  else start = symbols.findIndex(s => isVowelish(s.symbol));
  if (start < 0 || start >= symbols.length) return [];

  // Skip any articulatory marks sitting between the stress and its vowel.
  while (start < symbols.length && isStress(symbols[start]!.symbol)) start++;
  const run: TokenSlot[] = [];
  for (let i = start; i < symbols.length && isVowelish(symbols[i]!.symbol); i++) {
    run.push(symbols[i]!);
  }
  if (!run.length) return [];

  // A blank carries real speech duration here, not silence, so the blank
  // trailing each vowel belongs to the vowel.
  const first = run[0]!.index, last = run[run.length - 1]!.index;
  return slots.filter(s => s.index >= first
    && s.index <= last + 1 && (s.kind === "symbol" || s.kind === "blank"));
}

/**
 * One factor per token, aligned to `layout.ids` index for index.
 *
 * A blank inherits the class of the sound it trails, which is why the blank
 * after a plosive stays at exactly one: that gap is the stop's closure, and
 * stretching it is how a held word turns into a stutter.
 */
export function durationFactors(layout: TokenLayout,
                                directions: SoundDirection[]): Float32Array {
  const factors = new Float32Array(layout.ids.length).fill(1);
  const targeted = new Map<number, SoundDirection>();
  for (const d of directions) targeted.set(d.word, d);

  for (const [word, direction] of targeted) {
    for (const slot of wordSlots(layout, word)) {
      if (slot.kind !== "symbol" && slot.kind !== "blank") continue;
      const weight = susceptibility[phonemeClass(slot.symbol)];
      if (weight <= 0) continue;
      factors[slot.index] = clamp(1 + (direction.stretch - 1) * weight,
                                  factorRange.min, factorRange.max);
    }
    if (direction.accent <= 0) continue;
    for (const slot of nucleus(layout, word)) {
      const weight = susceptibility[phonemeClass(slot.symbol)];
      if (weight <= 0) continue;
      factors[slot.index] = clamp(factors[slot.index]! + direction.accent * weight,
                                  factorRange.min, factorRange.max);
    }
  }
  return factors;
}

/** Where each token begins and ends in the rendered audio, from the frame
 * counts the model reports back. This is the model's own alignment, not a
 * guess from a recogniser — which is the whole reason it can be trusted. */
export function sampleBounds(frames: ArrayLike<number>, hop: number): number[] {
  const bounds = [0];
  let total = 0;
  for (let i = 0; i < frames.length; i++) { total += frames[i]!; bounds.push(total * hop); }
  return bounds;
}

/**
 * The level lift over each accented word.
 *
 * Shaped around the nucleus rather than the word: the lift reaches full value
 * across the stressed vowel and ramps either side of it. A single cosine over
 * the whole word peaks at the word's midpoint, which lands on a consonant as
 * often as not — the lift was then loudest where the accent was not, which
 * reads as subtle however many dB it is given.
 *
 * Linear gain only, no compression. The ramps never run shorter than a frame,
 * so a word that opens straight onto its vowel still rises into the lift
 * instead of stepping into it.
 */
export function accentEnvelope(layout: TokenLayout, directions: SoundDirection[],
                               frames: ArrayLike<number>, samples: number,
                               hop: number): Float32Array {
  const envelope = new Float32Array(samples).fill(1);
  const bounds = sampleBounds(frames, hop);
  const at = (index: number) =>
    clamp(bounds[clamp(index, 0, bounds.length - 1)] ?? 0, 0, samples);

  for (const direction of directions) {
    if (!direction.accentDB) continue;
    const slots = wordSlots(layout, direction.word);
    if (!slots.length) continue;
    const wordStart = at(slots[0]!.index);
    const wordEnd = at(slots[slots.length - 1]!.index + 1);
    if (wordEnd - wordStart <= 1) continue;

    const core = nucleus(layout, direction.word);
    let holdStart = core.length ? at(core[0]!.index) : wordStart;
    let holdEnd = core.length ? at(core[core.length - 1]!.index + 1) : wordEnd;
    // Borrow a frame from the nucleus when there is no onset or coda to ramp
    // across, rather than stepping the gain and clicking.
    if (holdStart - wordStart < hop) holdStart = Math.min(holdEnd, wordStart + hop);
    if (wordEnd - holdEnd < hop) holdEnd = Math.max(holdStart, wordEnd - hop);

    const peak = Math.pow(10, direction.accentDB / 20) - 1;
    for (let i = wordStart; i < holdStart; i++) {
      const phase = (i - wordStart) / Math.max(1, holdStart - wordStart);
      envelope[i] = 1 + peak * 0.5 * (1 - Math.cos(Math.PI * phase));
    }
    for (let i = holdStart; i < holdEnd; i++) envelope[i] = 1 + peak;
    for (let i = holdEnd; i < wordEnd; i++) {
      const phase = (i - holdEnd) / Math.max(1, wordEnd - holdEnd);
      envelope[i] = 1 + peak * 0.5 * (1 + Math.cos(Math.PI * phase));
    }
  }
  return envelope;
}

/** What a direction actually bought, for printing next to the dial rather
 * than asserting a figure that was measured on some other voice. */
export function addedSeconds(base: ArrayLike<number>, actual: ArrayLike<number>,
                             hop: number, rate: number): number {
  let added = 0;
  for (let i = 0; i < base.length; i++) added += (actual[i] ?? 0) - base[i]!;
  return added * hop / rate;
}
