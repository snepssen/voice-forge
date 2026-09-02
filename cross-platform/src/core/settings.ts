/**
 * Every dial, with the range it is honest over and the reason it exists.
 *
 * Gateway Forge settles these and never shows them: a meditation tape wants one
 * voice that does not drift. This app is the other half of the same engine —
 * the same three numbers, on the outside, where a voiceover can be shaped.
 */
export interface SynthesisSettings {
  /** Pace. 1.1 is ten percent slower, 0.9 ten percent faster.
   *
   * 1.0 means "as trained", and what that is worth depends on the voice. See
   * `voiceNotes` — the 0.3% likeness figure was measured on snepssen-rode, and
   * the bundled voice reads 31% faster on identical copy. */
  lengthScale: number;
  /** How much the sound varies between draws. Not pace, and not pausing. */
  noiseScale: number;
  /** How much the *durations* vary — the cadence. At zero, two takes of a line
   * are near-identical: repeatable, and noticeably mechanical. */
  noiseW: number;

  /** Real silence between two sentences. Exact: they are separate calls. */
  sentenceGap: number;
  /** Silence at a paragraph break, replacing the sentence gap rather than
   * adding to it — two silences end to end is how "0.6 s" becomes 0.68. */
  paragraphGap: number;
  /** Extra padding phonemes at a clause break.
   *
   * **Not seconds, and that is the honest unit.** A clause break happens inside
   * one inference call, so it cannot be lengthened by splicing silence without
   * cutting the sentence in two — the cut that produced a stutter. Handing the
   * model more padding and letting its duration predictor spend it is
   * in-distribution and seamless, but a pad is not a fixed number of
   * milliseconds. The app measures what it buys. */
  clausePads: number;

  /** **2 is a measured optimum, not a floor.** These voices end on residual
   * breath rather than silence; padding gives the decay somewhere to land. Over
   * 7 lines x 5 runs x 4 variants, worst-case 60 ms tail RMS: 0.00605 at zero,
   * 0.00246 at one, 0.00079 at two, 0.00336 at three. Not monotonic — three is
   * worse than two, because too much room lets the model voice into it. */
  trailingPads: number;
  /** The voice learned "the recording stops here" at the full stop and
   * reproduces whatever sat at that cut. Only `.` — `?` and `!` carry
   * intonation worth keeping. */
  dropFinalFullStop: boolean;
  /** Read `$4.99` as "four dollars ninety-nine". The only setting that changes
   * the listener's words, and switchable for that reason. */
  spokenCurrency: boolean;
}

export const defaultSettings = (): SynthesisSettings => ({
  lengthScale: 1.0,
  noiseScale: 0.667,
  noiseW: 0.8,
  sentenceGap: 0.08,
  paragraphGap: 0.55,
  clausePads: 0,
  trailingPads: 2,
  dropFinalFullStop: true,
  spokenCurrency: true,
});

/** The range each dial is offered over. Kept here rather than in the view so a
 * check can assert the defaults sit inside their own ranges — the sort of thing
 * that silently stops being true after an edit. */
export const ranges = {
  lengthScale: [0.5, 2.0],
  noiseScale: [0.0, 1.5],
  noiseW: [0.0, 1.5],
  sentenceGap: [0.0, 2.0],
  paragraphGap: [0.0, 4.0],
  clausePads: [0, 12],
  trailingPads: [0, 6],
} as const;

export function isWithinRanges(s: SynthesisSettings): boolean {
  return (Object.keys(ranges) as (keyof typeof ranges)[]).every(k => {
    const [lo, hi] = ranges[k];
    const v = s[k] as number;
    return v >= lo && v <= hi;
  });
}
