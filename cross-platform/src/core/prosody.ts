/**
 * Deciding the dynamics instead of asking for them.
 *
 * The per-sound layer can hold any sound by any amount, but nobody wants to
 * direct a paragraph one phoneme at a time. This derives a performance from
 * the text, so the manual controls become a way to disagree with a reading
 * rather than the only way to get one.
 *
 * It leans on work espeak has already done. A phonemized sentence is not a
 * string of dictionary pronunciations: espeak has already reduced the function
 * words, demoted stress in context and run clitics together, so `I` arrives as
 * `aɪ` rather than `ˈaɪ` and `on the` arrives as one group, `ɔnðə`. That means
 * the stream itself says which words carry weight — a group with a primary
 * stress mark is one the language wants heard, and a group with none has
 * already been told to get out of the way. No word list, and no mapping back
 * to written words, which is just as well: written words do not survive the
 * journey one for one.
 *
 * What espeak does not know is which word is the *point* of the sentence, and
 * Piper then renders whatever is left at an even distance. Three rules, no
 * model: put the accent where the phrase is heading, let a phrase end settle,
 * and stop hitting a word that has already been heard.
 */

import { clauseMarks } from "./script.js";
import { primaryStress, secondaryStress } from "./phonology.js";
import { fullAccentDB, wordPhonemes, type SoundDirection } from "./timingPlan.js";
import type { TokenLayout } from "../main/engine.js";

export interface ProsodySettings {
  /** How firmly the point of each phrase is made. Zero renders flat. */
  focus: number;
  /** How much a phrase settles before its boundary. */
  phraseFinal: number;
  /** How far a word already heard in this paragraph steps back. */
  deaccentRepeats: number;
  /** How much unstressed material gives way, to keep the beats uneven. */
  contrast: number;
  /** Extra hold on every accented nucleus, past what focus alone gives. */
  nucleusHold: number;
  /** What a full accent is worth in level. */
  accentDB: number;
  /** Where the line sits between flat and lifted, -1 to 1. The only control
   * the model answers to with its own intonation rather than a filter. */
  lift: number;
}

export const defaultProsody = (): ProsodySettings =>
  ({ focus: 0.7, phraseFinal: 0.15, deaccentRepeats: 0.6, contrast: 0.12,
     nucleusHold: 0, accentDB: fullAccentDB, lift: 0 });

/**
 * What each rule is worth at full strength.
 *
 * These are large because anything smaller does not exist. The graph rounds
 * every token's duration up to a whole frame, and the median token on this
 * voice is two frames — so a 5% direction moves 1 token in 123, and a 10% one
 * moves 2. A direction has to reach roughly 20% before it is audible at all.
 * The defaults above are scaled down to compensate, which keeps the reading
 * that was approved by ear exactly where it was while giving a preset somewhere
 * to go.
 */
const holds = { focus: 0.3, phraseFinal: 1.15, contrast: 0.35 } as const;

export type Prominence = "accented" | "secondary" | "reduced";

export interface ProsodicGroup {
  /** Index of the group within the phoneme stream, which is what a direction
   * addresses — not the index of a written word. */
  word: number;
  phonemes: string;
  prominence: Prominence;
  /** Carries a clause mark, so the phrase turns over after it. */
  endsPhrase: boolean;
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Stress and punctuation removed, so "garden" and "garden," are one word
 * again when asking whether it has already been said. */
export const groupKey = (phonemes: string): string =>
  [...phonemes].filter(c => c !== primaryStress && c !== secondaryStress
    && !clauseMarks.has(c) && !/[.?!]/.test(c)).join("");

export function prosodicGroups(layout: TokenLayout): ProsodicGroup[] {
  const groups: ProsodicGroup[] = [];
  for (let word = 0; word < layout.words; word++) {
    const phonemes = wordPhonemes(layout, word);
    if (!phonemes) continue;
    groups.push({
      word, phonemes,
      prominence: phonemes.includes(primaryStress) ? "accented"
        : phonemes.includes(secondaryStress) ? "secondary" : "reduced",
      endsPhrase: [...phonemes].some(c => clauseMarks.has(c) || /[.?!]/.test(c)),
    });
  }
  return groups;
}

/**
 * A reading of one sentence, as directions the per-sound layer can render.
 *
 * `spoken` carries the words already heard earlier in the paragraph, so a
 * repeat can step back the way a person's would. It is read, never written to.
 */
export function automaticDirections(layout: TokenLayout,
                                    settings: ProsodySettings = defaultProsody(),
                                    spoken: ReadonlySet<string> = new Set()): SoundDirection[] {
  const groups = prosodicGroups(layout);
  if (!groups.length) return [];
  const directions = new Map<number, SoundDirection>();

  // Unstressed material gives way a little. This is the whole thesis of the
  // app in one line: the beats are supposed to be uneven.
  if (settings.contrast > 0) {
    for (const group of groups) {
      if (group.prominence !== "reduced") continue;
      directions.set(group.word,
        { word: group.word, stretch: 1 - holds.contrast * clamp(settings.contrast, 0, 1),
          accent: 0, accentDB: 0 });
    }
  }

  // Each phrase gets one point, made on the last word able to carry it.
  for (const phrase of phrases(groups)) {
    const carriers = phrase.filter(g => g.prominence === "accented");
    const nucleus = carriers.at(-1) ?? phrase.filter(g => g.prominence === "secondary").at(-1);
    if (nucleus) {
      const repeated = spoken.has(groupKey(nucleus.phonemes));
      const strength = clamp(settings.focus, 0, 1)
        * (repeated ? 1 - clamp(settings.deaccentRepeats, 0, 1) : 1);
      directions.set(nucleus.word, {
        word: nucleus.word,
        stretch: 1 + holds.focus * strength,
        accent: 0.6 * strength + Math.max(0, settings.nucleusHold),
        accentDB: Math.max(0, settings.accentDB) * strength,
      });
    }

    // A phrase settles at its edge whether or not the point was made there.
    const last = phrase.at(-1);
    if (last && settings.phraseFinal > 0 && last.prominence !== "reduced") {
      const hold = 1 + holds.phraseFinal * clamp(settings.phraseFinal, 0, 1);
      const existing = directions.get(last.word);
      directions.set(last.word, existing
        ? { ...existing, stretch: Math.max(existing.stretch, hold) }
        : { word: last.word, stretch: hold, accent: 0, accentDB: 0 });
    }
  }

  // A direction that changes nothing is not a direction. Emitting one would
  // mark a word as directed in the interface and leave somebody looking for
  // the difference it made.
  return [...directions.values()]
    .filter(d => d.stretch !== 1 || d.accent !== 0 || d.accentDB !== 0)
    .sort((a, b) => a.word - b.word);
}

/** Split at clause marks, so each phrase can make its own point. */
function phrases(groups: ProsodicGroup[]): ProsodicGroup[][] {
  const out: ProsodicGroup[][] = [];
  let current: ProsodicGroup[] = [];
  for (const group of groups) {
    current.push(group);
    if (group.endsPhrase) { out.push(current); current = []; }
  }
  if (current.length) out.push(current);
  return out;
}

/** Every word this sentence has now said, to carry into the next one. */
export const spokenKeys = (layout: TokenLayout): Set<string> =>
  new Set(prosodicGroups(layout).map(g => groupKey(g.phonemes)));
