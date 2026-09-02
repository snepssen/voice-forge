/**
 * What is known about each voice, and — as important — which voice it was
 * learned from.
 *
 * This exists because a claim got attached to the wrong thing. The pace dial
 * said "the reader's own rate, measured to within 0.3%" under every voice. The
 * measurement is real but was made on **snepssen-rode** against the reader's
 * own recordings; the bundled voice was fine-tuned on generated audio and on
 * identical copy reads **31% faster** — 194 words a minute against 148, with
 * commas worth 145 ms against 457. Printing one under the other was false.
 */
export interface VoiceNote {
  name: string;
  summary: string;
  /** What lengthScale 1.0 means for *this* voice, or null when nobody has
   * measured it against a reference. */
  paceReference: string | null;
  typicalWPM: number | null;
}

export const voiceNotes: VoiceNote[] = [
  {
    name: "snepssen",
    summary: "The voice this app ships with. Measured on ordinary prose: 194 words a minute, commas worth about 145 ms.",
    paceReference: null,
    typicalWPM: 194,
  },
  {
    name: "snepssen-rode",
    summary: "Fine-tuned on the reader's own microphone recordings. Slower and closer to life: 148 words a minute, commas worth about 457 ms.",
    paceReference: "The reader's own rate, measured to within 0.3% against their own recordings. A departure from here is a choice, not a correction.",
    typicalWPM: 148,
  },
];

export const noteFor = (name: string): VoiceNote | undefined =>
  voiceNotes.find(v => v.name === name);

/** What to print under the pace dial for a given voice and value. */
export function paceNote(voice: string, lengthScale: number): string {
  const atOne = Math.abs(lengthScale - 1) < 0.005;
  const reference = noteFor(voice)?.paceReference ?? null;
  if (atOne) {
    return reference
      ?? "This voice's own rate — where it was trained, not a likeness anybody has measured against a reference recording.";
  }
  const percent = Math.round((lengthScale - 1) * 100);
  const base = percent > 0 ? `${percent}% slower` : `${-percent}% faster`;
  const wpm = noteFor(voice)?.typicalWPM;
  if (wpm != null) {
    return `${base} than this voice's own ${wpm} words a minute — about ${Math.round(wpm / lengthScale)}.`;
  }
  // An installed voice nobody here has measured. Borrowing another voice's
  // rate would be a guess dressed as a measurement.
  return `${base} than this voice's own rate, whatever that is — this voice has not been measured here.`;
}
