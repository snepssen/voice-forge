/**
 * What each sound will and will not tolerate being held.
 *
 * Stretching a whole word uniformly is what made "stole" read as "ssttoollee":
 * the ear hears a held /s/ and a smeared /t/ as a defect, and a held vowel as
 * delivery. So a request to slow a word down is not one number applied to its
 * tokens — it is one number weighted per sound, and a plosive's weight is zero.
 *
 * The classes below describe the espeak IPA the bundled voice actually emits,
 * one Unicode code point at a time, because that is the granularity the model's
 * phoneme id map is addressed at. Diphthongs arrive as two code points and the
 * length mark as a third, which is a gift: it means the nucleus of a syllable
 * can be held without touching the consonants around it.
 */

export const phonemeClasses = [
  "vowel", "vowelExtension", "sonorant", "voicedFricative",
  "voicelessFricative", "plosive", "marker", "boundary",
] as const;
export type PhonemeClass = typeof phonemeClasses[number];

const members: Record<Exclude<PhonemeClass, "boundary">, string> = {
  // Monophthongs and the halves of the diphthongs espeak splits.
  vowel: "aeiouyæøœɐɑɒɔɘəɚɛɜɝɞɤɨɪɯɵɶʉʊʌʏᵻε",
  // Not sounds of their own: they say the vowel before them is held longer.
  vowelExtension: "ːˑ˞",
  // Voiced and continuant. These hold without turning into noise.
  sonorant: "mnŋɱɲɳɴlɫɭʎʟɹɻrɾɽʀɺjwɥɰ",
  // Voiced friction. Holds, but becomes a buzz well before a vowel would.
  voicedFricative: "vðzʒʐʑʝɣʁʕβɦɮʋ",
  // Unvoiced friction. Holding one is just a longer hiss.
  voicelessFricative: "fθsʃçxχɸʂɕɬħhʍɧ",
  // Closure and burst. Holding one does not lengthen a sound, it invents a gap.
  plosive: "pbtdkɡgqcɟɢʔʈɖɓɗʄɠʛʡʢʦʘǀǁǂǃʙⱱ",
  // Stress, aspiration and articulatory detail. They carry no duration to give.
  marker: "ˈˌʰʲʷˤ̧̪̯̩̺̻̝̃̊↓↑",
};

const lookup = new Map<string, PhonemeClass>();
for (const [name, symbols] of Object.entries(members)) {
  for (const symbol of symbols) lookup.set(symbol, name as PhonemeClass);
}

/** Anything not named above — punctuation, digits, the word space — is a
 * boundary rather than a guess, so an unexpected symbol is never stretched. */
export const phonemeClass = (symbol: string): PhonemeClass =>
  lookup.get(symbol) ?? "boundary";

/**
 * How much of a requested stretch each class actually receives.
 *
 * Only the two ends of this scale are settled by listening: the vowel took a
 * whole direction and was preferred, the word took a whole direction through
 * its stops and was rejected. The values between them are a starting ordering
 * — voiced continuants hold better than unvoiced friction — and are the first
 * thing to retune if a take sounds wrong, not a measured constant.
 */
export const susceptibility: Record<PhonemeClass, number> = {
  vowel: 1,
  vowelExtension: 1,
  sonorant: 0.55,
  voicedFricative: 0.4,
  voicelessFricative: 0.12,
  plosive: 0,
  marker: 0,
  boundary: 0,
};

export const isVowelish = (symbol: string): boolean => {
  const c = phonemeClass(symbol);
  return c === "vowel" || c === "vowelExtension";
};

/** The stress marks espeak writes immediately before the syllable they belong
 * to, which is what makes an accent addressable without a syllabifier. */
export const primaryStress = "ˈ";
export const secondaryStress = "ˌ";
export const isStress = (symbol: string): boolean =>
  symbol === primaryStress || symbol === secondaryStress;
