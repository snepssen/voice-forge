/**
 * A script, cut the way the model wants to be fed.
 *
 * **One inference call per sentence, never less, never more.** Not a
 * preference — what the engine was measured into. Flattening several sentences
 * into one call is off-distribution (Piper phonemizes a sentence at a time, and
 * so did the fine-tuning) and was heard as a phantom "-eth" on the last
 * sentence in eight draws of eight. Cutting *inside* a sentence is the opposite
 * error: each call starts cold with no audio context, heard as "y-you".
 *
 * Ported from the Swift original. The rules are the same rules and the checks
 * are the same checks — that is the point of porting them alongside.
 */

export interface Sentence {
  id: number;
  text: string;
  /** Which paragraph it belongs to. A paragraph break is a longer pause. */
  paragraph: number;
  endsParagraph: boolean;
  /** The punctuation it ends on, or "" when it just stops. */
  terminator: string;
  /** How many `,` `;` `:` `—` it contains. */
  clauseBreaks: number;
}

export interface Script {
  sentences: Sentence[];
}

/** The marks treated as a clause break inside a sentence.
 *
 * espeak-ng's own clause terminators. The em dash is included because writing
 * for voiceover uses it as a breath and espeak gives it one; the hyphen is not,
 * because it joins rather than separates. */
export const clauseMarks = new Set([",", ";", ":", "—"]);

/**
 * Words that end in a full stop without ending a sentence.
 *
 * Found by stress-testing rather than imagined. "Dr. Smith paid $4.99 on Jan.
 * 3rd, i.e. last Tuesday" was cut into four utterances — `Dr.` alone was a
 * 0.63-second "sentence" — each with its own inference call, its own falling
 * intonation and its own gap. It never crashed. It read like a broken machine.
 */
export const abbreviations = new Set([
  "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "rev", "hon",
  "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
  "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
  "vs", "etc", "approx", "est", "fig", "vol", "no", "ed", "eds", "pp", "ch",
  "inc", "ltd", "co", "corp", "dept", "univ", "min", "max", "avg",
  "ave", "blvd", "rd", "apt",
]);

/**
 * Whether a terminator at `i` really ends a sentence.
 *
 * `!` and `?` always do. A full stop is the hard one, and three things stop it:
 * a decimal point (`3.14`, `$4.99`), an abbreviation (`Dr.`, `Jan.`), and an
 * initialism (`U.S.`, `i.e.` — the letter before the stop stands alone).
 *
 * A "the next word is lowercase" test was tried and **removed**: it fixed
 * `U.K. disagree` for the wrong reason and merged "ALL CAPS SHOUTING. mixed
 * CaSe." into one utterance, and people write scripts in lowercase all the time.
 *
 * Where genuinely ambiguous — "I moved to the U.S. Then I left" — this joins
 * rather than splits. The costs are not symmetric: joining gives one longer
 * inference call, which the model handles; splitting gives a false full stop
 * and a falling intonation in the middle of a thought.
 */
export function endsSentence(chars: string[], i: number): boolean {
  const ch = chars[i];
  if (ch !== "." && ch !== "!" && ch !== "?") return false;

  let j = i + 1;
  while (j < chars.length && chars[j] === " ") j += 1;
  const sawSpace = j > i + 1 || j >= chars.length || chars[j] === "\n";
  const next = j < chars.length ? chars[j] : undefined;

  // A terminator must be followed by whitespace or the end of the text, so
  // `3.14` and `example.com` are not boundaries.
  if (!sawSpace && next !== undefined) return false;
  if (ch !== ".") return true;

  let k = i - 1;
  let word = "";
  while (k >= 0 && /\p{L}/u.test(chars[k]!)) { word = chars[k]! + word; k -= 1; }

  // An initialism: a lone letter whose own stop is right behind it.
  if (word.length === 1 && k >= 0 && chars[k] === ".") return false;
  if (abbreviations.has(word.toLowerCase())) return false;
  return true;
}

export function splitSentences(text: string): string[] {
  const out: string[] = [];
  let current = "";
  const chars = [...text];
  for (let i = 0; i < chars.length; i++) {
    current += chars[i];
    if (!endsSentence(chars, i)) continue;
    const t = current.trim();
    if (t) out.push(t);
    current = "";
  }
  const tail = current.trim();
  if (tail) out.push(tail);
  return out;
}

/** Cut a script into paragraphs and sentences. A blank line starts a paragraph. */
export function parseScript(text: string): Script {
  const sentences: Sentence[] = [];
  let id = 0;
  const paragraphs = text.split("\n\n").map(p => p.trim()).filter(Boolean);

  paragraphs.forEach((paragraph, p) => {
    const pieces = splitSentences(paragraph);
    pieces.forEach((piece, i) => {
      const last = piece.at(-1) ?? "";
      sentences.push({
        id: id++,
        text: piece,
        paragraph: p,
        endsParagraph: i === pieces.length - 1,
        terminator: ".!?".includes(last) ? last : "",
        clauseBreaks: [...piece].filter(c => clauseMarks.has(c)).length,
      });
    });
  });
  return { sentences };
}

export const wordCount = (s: Script): number =>
  s.sentences.reduce((n, x) => n + x.text.split(/\s+/).filter(Boolean).length, 0);

export const paragraphCount = (s: Script): number =>
  s.sentences.length ? Math.max(...s.sentences.map(x => x.paragraph)) + 1 : 0;

/**
 * Give an em dash the spaces espeak needs in order to see it.
 *
 * **Measured.** `quiet — and` phonemizes to `kwˈaɪət; ænd` — espeak turns a
 * spaced em dash into a semicolon clause break, which is why `;` and `—`
 * calibrate to the same number. `quiet—and` gives `kwˈaɪət ænd`,
 * byte-identical to writing no dash at all. The mark is dropped.
 *
 * That matters because the pause dial names `—` among the marks it gives room
 * to, so for `word—word` — how most people type one — it was giving room to a
 * break that did not exist. This is whitespace around punctuation, not a
 * respelling: no word changes. A hyphen is left alone, because it joins rather
 * than separates and espeak correctly runs `hyphenated-words` together.
 */
export function spacedEmDashes(text: string): string {
  if (!text.includes("—")) return text;
  let out = "";
  let pending = false;
  for (const ch of text) {
    if (ch === "—") {
      if (!out.endsWith(" ")) out += " ";
      out += "—";
      pending = true;
    } else if (pending) {
      out += ch === " " ? " " : ` ${ch}`;
      pending = false;
    } else {
      out += ch;
    }
  }
  return out;
}

/**
 * Currency symbols and the words they are actually spoken as.
 *
 * espeak reads the symbol first and the number after, as written: `$4.99` is
 * "dollar four point nine nine", and every currency does the same — "pound four
 * point nine nine", "euros four point nine nine", "yen four hundred". Nobody
 * says that. English puts the amount first and the currency after, and reads
 * the part after the point as a second number rather than as decimals.
 *
 * Yen, won and lira take no plural s.
 */
export const currencies: { symbol: string; singular: string; plural: string }[] = [
  { symbol: "$", singular: "dollar", plural: "dollars" },
  { symbol: "£", singular: "pound", plural: "pounds" },
  { symbol: "€", singular: "euro", plural: "euros" },
  { symbol: "¥", singular: "yen", plural: "yen" },
  { symbol: "₩", singular: "won", plural: "won" },
  { symbol: "₺", singular: "lira", plural: "lira" },
  { symbol: "₽", singular: "ruble", plural: "rubles" },
  { symbol: "₹", singular: "rupee", plural: "rupees" },
  { symbol: "¢", singular: "cent", plural: "cents" },
];

/**
 * Rewrite written currency into the order it is spoken.
 *
 *     $4.99   ->  4 dollars 99          £4.50  ->  4 pounds 50
 *     $1      ->  1 dollar              ¥400   ->  400 yen
 *     $4.00   ->  4 dollars             $4.05  ->  4 dollars oh 5
 *
 * **The one place the app rewrites the listener's words, and switchable for
 * exactly that reason.** A symbol not followed by a digit is left alone, so
 * `$PATH` in a code sample survives.
 */
export function spokenCurrency(text: string): string {
  if (!currencies.some(c => text.includes(c.symbol))) return text;
  const chars = [...text];
  let out = "";
  let i = 0;
  while (i < chars.length) {
    const money = currencies.find(c => c.symbol === chars[i]);
    if (!money) { out += chars[i]; i += 1; continue; }

    let j = i + 1;
    let whole = "";
    while (j < chars.length &&
           (/\d/.test(chars[j]!) ||
            (chars[j] === "," && j + 1 < chars.length && /\d/.test(chars[j + 1]!)))) {
      whole += chars[j]; j += 1;
    }
    if (!whole) { out += chars[i]; i += 1; continue; }

    // A point followed by digits is either a minor unit or part of the number.
    // Exactly two digits is cents; anything else belongs to the amount.
    // Getting this wrong produced `$3.14159` -> "3 dollars.14159", the currency
    // word wedged into the middle of its own number.
    let minor: string | undefined;
    if (j < chars.length && chars[j] === ".") {
      let k = j + 1;
      let digits = "";
      while (k < chars.length && /\d/.test(chars[k]!)) { digits += chars[k]; k += 1; }
      if (digits.length === 2) { minor = digits; j = k; }
      else if (digits) { whole += "." + digits; j = k; }
    }

    const isOne = whole.replace(/,/g, "") === "1";
    out += whole + " " + (isOne ? money.singular : money.plural);
    if (minor && minor !== "00") {
      // "oh five", not "zero five" — it is how a price is read.
      out += minor.startsWith("0") ? ` oh ${minor.slice(1)}` : ` ${minor}`;
    }
    i = j;
  }
  return out;
}
