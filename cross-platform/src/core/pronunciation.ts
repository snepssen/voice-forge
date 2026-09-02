/**
 * A word, and how this voice should say it.
 *
 * The override is IPA because that is what the model consumes: espeak hands it
 * IPA symbols and the voice knows 161 of them. Writing IPA is not a translation
 * step — it *is* the thing.
 *
 * espeak-ng's own inline syntax, `[[sn'ɛpsən]]`, was tested and rejected: it
 * does not work through this call path at all. espeak reads the brackets as
 * literal text and pronounces the IPA *by name* — "S N stress open-E P E S
 * schwa N", spoken aloud. So substitution is done here: phonemize the word on
 * its own to learn what espeak says, then replace exactly that in the sentence.
 */

export type Scope = "global" | "project";

export interface PronunciationEntry {
  id: string;
  word: string;
  ipa: string;
  scope: Scope;
  enabled: boolean;
}

export const entryKey = (e: PronunciationEntry) => e.word.toLowerCase();

/**
 * What is wrong with an entry.
 *
 * **Validation is the whole safety mechanism, not politeness.** The phoneme
 * mapper skips an unknown symbol rather than failing, so a bad entry costs a
 * sound and says nothing. Measured against the real vocabulary rather than
 * imagined — an earlier version invented a vocabulary where ASCII `r` was
 * absent and asserted it would be refused, against voices that carry `r` as the
 * IPA alveolar trill. The fixture was asserting something untrue of the thing
 * it stood for.
 */
export interface PronunciationProblem {
  /** Characters the voice has no phoneme for — **silently discarded**. What
   * actually vanishes: the `/slashes/` a dictionary quotes IPA in, `[brackets]`,
   * capitals, accented Latin. */
  unknownSymbols: string[];
  /** Punctuation the model knows *as punctuation*. Worse than dropping: `.` is
   * the full-stop phoneme, so a syllable dot inserts a sentence boundary in the
   * middle of a word. */
  punctuationSymbols: string[];
  /** Valid IPA, present, and almost certainly not meant. ASCII `r` is Spanish's
   * trill; ASCII `g` and IPA `ɡ` look identical in most fonts and are different
   * phonemes. Both are real IPA, so they warn rather than block. */
  lookalikes: { typed: string; meant: string; name: string }[];
  isEmpty: boolean;
}

const punctuation = new Set([".", ",", ";", ":", "?", "!", "(", ")", '"', "-"]);
const lookalikeTable = [
  { typed: "r", meant: "ɹ", name: "the trilled r of Spanish or Italian" },
  { typed: "g", meant: "ɡ", name: "a different letter from the IPA g, though most fonts draw them alike" },
];

export const isBlocking = (p: PronunciationProblem) =>
  p.unknownSymbols.length > 0 || p.punctuationSymbols.length > 0 || p.isEmpty;
export const hasWarning = (p: PronunciationProblem) => p.lookalikes.length > 0;

const named = (s: string) =>
  `${s} (U+${(s.codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, "0")})`;

export function problemMessage(p: PronunciationProblem): string {
  if (p.isEmpty) return "Nothing to say.";
  const parts: string[] = [];
  if (p.unknownSymbols.length) {
    parts.push(`This voice has no ${p.unknownSymbols.map(named).join(" ")} — it would be dropped and the sound lost.`
      + (p.unknownSymbols.includes("/") || p.unknownSymbols.includes("[")
        ? " Write the symbols on their own, without the brackets a dictionary quotes them in." : ""));
  }
  if (p.punctuationSymbols.length) {
    parts.push(`${p.punctuationSymbols.map(named).join(" ")} is punctuation to this model, not a sound — inside a word it would break the sentence in half.`);
  }
  for (const l of p.lookalikes) {
    parts.push(`${named(l.typed)} is ${l.name}. For English you almost certainly want ${named(l.meant)}.`);
  }
  return parts.join(" ");
}

export function checkPronunciation(ipa: string, vocabulary: Set<string>): PronunciationProblem {
  const trimmed = ipa.trim();
  const unknownSymbols: string[] = [];
  const punctuationSymbols: string[] = [];
  const lookalikes: PronunciationProblem["lookalikes"] = [];
  for (const s of [...trimmed]) {
    if (s === " ") continue;
    if (!vocabulary.has(s)) {
      if (!unknownSymbols.includes(s)) unknownSymbols.push(s);
    } else if (punctuation.has(s)) {
      if (!punctuationSymbols.includes(s)) punctuationSymbols.push(s);
    } else {
      const l = lookalikeTable.find(x => x.typed === s);
      if (l && !lookalikes.some(x => x.typed === s)) lookalikes.push(l);
    }
  }
  return { unknownSymbols, punctuationSymbols, lookalikes, isEmpty: trimmed.length === 0 };
}

/**
 * The entries in force, one per word.
 *
 * A project entry beats a global one for the same word — that is what
 * "override" means, resolved here rather than at the point of use so there is
 * one answer to "what will this say".
 */
export function effectiveEntries(entries: PronunciationEntry[]): PronunciationEntry[] {
  const byWord = new Map<string, PronunciationEntry>();
  for (const e of entries) {
    if (!e.enabled || !e.ipa) continue;
    const existing = byWord.get(entryKey(e));
    if (existing && existing.scope === "project" && e.scope === "global") continue;
    byWord.set(entryKey(e), e);
  }
  return [...byWord.values()].sort((a, b) => a.word.toLowerCase() < b.word.toLowerCase() ? -1 : 1);
}

/** True when a global entry is shadowed by a project one. An entry that does
 * nothing should look like it. */
export function isShadowed(entry: PronunciationEntry, entries: PronunciationEntry[]): boolean {
  if (entry.scope !== "global" || !entry.enabled) return false;
  return entries.some(e => entryKey(e) === entryKey(entry) && e.scope === "project" && e.enabled);
}

const isPhonemeSymbol = (c: string) => {
  const v = c.codePointAt(0) ?? 0;
  return (v >= 0x0250 && v <= 0x02ff) || (v >= 0x0300 && v <= 0x036f)
      || (v >= 0x1d00 && v <= 0x1d7f) || /\p{L}/u.test(c);
};

function matches(window: string[], want: string[]): [boolean, string] {
  if (window.length !== want.length || !window.length) return [false, ""];
  for (let i = 0; i < window.length - 1; i++) if (window[i] !== want[i]) return [false, ""];
  const last = window.at(-1)!, wantLast = want.at(-1)!;
  if (!last.startsWith(wantLast)) return [false, ""];
  const tail = last.slice(wantLast.length);
  // Only punctuation may trail; anything else is a longer word that merely
  // starts the same way.
  if ([...tail].some(isPhonemeSymbol)) return [false, ""];
  return [true, tail];
}

/**
 * Apply the dictionary to one sentence's phonemes.
 *
 * Matching is on whole space-separated groups, never bare substring: espeak
 * separates words with spaces, and `replace` would happily rewrite the middle
 * of a longer word.
 */
export function applyDictionary(
  entries: PronunciationEntry[], phonemes: string, defaults: Map<string, string>
): { phonemes: string; applied: Set<string> } {
  let groups = phonemes.split(" ");
  const applied = new Set<string>();
  for (const entry of entries) {
    const fallback = defaults.get(entryKey(entry));
    if (!fallback) continue;
    const want = fallback.split(" ").filter(Boolean);
    if (!want.length) continue;
    let i = 0;
    while (i + want.length <= groups.length) {
      const [ok, tail] = matches(groups.slice(i, i + want.length), want);
      if (ok) {
        groups.splice(i, want.length, entry.ipa + tail);
        applied.add(entryKey(entry));
      }
      i += 1;
    }
  }
  return { phonemes: groups.join(" "), applied };
}
