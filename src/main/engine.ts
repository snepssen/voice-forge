import * as ort from "onnxruntime-node";
import { readFileSync, readdirSync } from "fs";
import { join } from "path";
import { initialize as initEspeak, phonemize } from "piper-phonemize";
import type { SynthesisSettings } from "../core/settings.js";
import { clauseMarks, spacedEmDashes, spokenCurrency, type Script } from "../core/script.js";
import { applyDictionary, entryKey, type PronunciationEntry } from "../core/pronunciation.js";
import { scanVoices, mergeVoices, type VoiceProfile, type VoiceRejection } from "../core/voiceLibrary.js";
import { voicesDir } from "../core/paths.js";

interface PiperVoiceConfig {
  audio: { sample_rate: number };
  espeak: { voice: string };
  inference: { noise_scale: number; length_scale: number; noise_w: number };
  phoneme_id_map: Record<string, number[]>;
}

export interface RenderedSentence {
  id: number;
  text: string;
  samples: Float32Array;
  /** Silence laid *after* this sentence before the next begins. */
  trailingGap: number;
  seconds: number;
  peakDBFS: number;
  wordsPerMinute: number;
}

/**
 * The synthesiser, with its dials on the outside.
 *
 * The same engine as the Mac app's, arrived at the same way. The two decisions
 * it was measured into are kept as settings rather than constants: one
 * inference call per sentence, and two trailing padding phonemes with the final
 * full stop dropped.
 *
 * **espeak-ng's data is this app's, not the npm package's.** `piper-phonemize`
 * bundles a newer espeak-ng whose en-us rules moved the NORTH/FORCE vowel from
 * `ɔːɹ` to `oːɹ` — measured across 35 ordinary words, 8 differed and every
 * difference was that one, in *four, before, more, door, course, report*. The
 * model was trained on `ɔːɹ`. Pointing the phonemizer at the data this app
 * ships makes it byte-identical to the Mac build, and that is the only reason
 * the two platforms sound the same.
 */
export class VoiceEngine {
  private constructor(
    readonly voice: string,
    private readonly session: ort.InferenceSession,
    private readonly config: PiperVoiceConfig,
    private readonly resourcesDir: string,
  ) {}

  private defaultPhonemeCache = new Map<string, string>();

  get sampleRate(): number { return this.config.audio.sample_rate; }

  /** Every symbol this voice knows — the alphabet a dictionary entry may use. */
  get vocabulary(): Set<string> {
    return new Set(Object.keys(this.config.phoneme_id_map).filter(k => [...k].length === 1));
  }

  static async open(profile: VoiceProfile, resourcesDir: string): Promise<VoiceEngine> {
    VoiceEngine.useEspeakData(resourcesDir);
    const config = JSON.parse(readFileSync(profile.configPath, "utf8")) as PiperVoiceConfig;
    const session = await ort.InferenceSession.create(profile.modelPath);
    return new VoiceEngine(profile.name, session, config, resourcesDir);
  }

  static bundledProfiles(resourcesDir: string): VoiceProfile[] {
    const dir = join(resourcesDir, "voices");
    try { return scanVoices(readdirSync(dir), dir, true).voices; } catch { return []; }
  }

  static installedProfiles(): { voices: VoiceProfile[]; rejected: VoiceRejection[] } {
    const dir = voicesDir();
    try { return scanVoices(readdirSync(dir), dir, false); } catch { return { voices: [], rejected: [] }; }
  }

  static availableVoices(resourcesDir: string): VoiceProfile[] {
    return mergeVoices(this.bundledProfiles(resourcesDir), this.installedProfiles().voices);
  }

  // MARK: phonemes

  /** espeak-ng is process-global: `initialize` may only be pointed at a data
   * directory once, no matter how many voices get opened. */
  private static espeakReady = false;
  static useEspeakData(parentDir: string): void {
    if (VoiceEngine.espeakReady) return;
    initEspeak(parentDir);
    VoiceEngine.espeakReady = true;
  }

  private espeak(text: string): string {
    const arrays = phonemize(spacedEmDashes(text), this.config.espeak.voice);
    return arrays.map(a => String.fromCodePoint(...a)).join(" ");
  }

  /** What espeak says for a word on its own, cached — a ten-word dictionary
   * would otherwise phonemize those ten words once per sentence. */
  async defaultPhonemes(word: string): Promise<string> {
    const key = word.toLowerCase();
    const hit = this.defaultPhonemeCache.get(key);
    if (hit !== undefined) return hit;
    const value = this.espeak(word);
    this.defaultPhonemeCache.set(key, value);
    return value;
  }

  /**
   * The phonemes a sentence will actually be spoken from, with the dictionary
   * applied, and which entries landed.
   *
   * `applied` is reported rather than assumed: the substitution finds a word by
   * phonemizing it alone and matching that in the sentence, which holds for
   * ordinary prose but stress can move in context — and an entry that quietly
   * does nothing is the failure this feature exists to stop.
   */
  async phonemesFor(text: string, settings: SynthesisSettings, dictionary: PronunciationEntry[] = []):
    Promise<{ phonemes: string; applied: Set<string> }> {
    // The one rewrite of the listener's words, and theirs to switch off.
    const source = settings.spokenCurrency ? spokenCurrency(text) : text;
    let base = this.espeak(source);
    if (settings.dropFinalFullStop && base.endsWith(".")) base = base.slice(0, -1).trimEnd();
    if (!dictionary.length) return { phonemes: base, applied: new Set() };
    const defaults = new Map<string, string>();
    for (const e of dictionary) defaults.set(entryKey(e), await this.defaultPhonemes(e.word));
    return applyDictionary(dictionary, base, defaults);
  }

  /**
   * Phonemes to model ids: BOS, PAD after every phoneme, EOS.
   *
   * Iterates by codepoint, matching Python's `list(str)` — grapheme clustering
   * would group a base letter with a following combining diacritic and silently
   * fail to match either half's separate entry.
   *
   * `clausePads` adds PAD ids after a clause mark. PAD is a phoneme the model
   * saw everywhere in training, so spending more of them at a breath is
   * in-distribution — unlike cutting the sentence at the comma, which puts a
   * cold start where a breath belongs and was heard as a stutter.
   */
  phonemeIds(phonemes: string, settings: SynthesisSettings): number[] {
    const map = this.config.phoneme_id_map;
    const pad = map["_"] ?? [];
    const ids: number[] = [...(map["^"] ?? []), ...pad];
    for (const ch of [...phonemes]) {
      const id = map[ch];
      if (!id) continue;
      ids.push(...id, ...pad);
      if (settings.clausePads > 0 && clauseMarks.has(ch)) {
        for (let i = 0; i < settings.clausePads; i++) ids.push(...pad);
      }
    }
    for (let i = 0; i < settings.trailingPads; i++) ids.push(...pad);
    ids.push(...(map["$"] ?? []));
    return ids;
  }

  /** One sentence, one inference call. Never less, never more. */
  async renderSentence(text: string, settings: SynthesisSettings,
                       dictionary: PronunciationEntry[] = []): Promise<Float32Array> {
    const { phonemes } = await this.phonemesFor(text, settings, dictionary);
    const ids = this.phonemeIds(phonemes, settings);
    if (!ids.length) return new Float32Array(0);
    const out = await this.session.run({
      input: new ort.Tensor("int64", BigInt64Array.from(ids.map(BigInt)), [1, ids.length]),
      input_lengths: new ort.Tensor("int64", BigInt64Array.from([BigInt(ids.length)]), [1]),
      // The order is the model's, not ours: noise, length, noise_w.
      scales: new ort.Tensor("float32",
        Float32Array.from([settings.noiseScale, settings.lengthScale, settings.noiseW]), [3]),
    });
    return out["output"]!.data as Float32Array;
  }

  async render(script: Script, settings: SynthesisSettings, dictionary: PronunciationEntry[] = [],
               onProgress?: (done: number, total: number) => void): Promise<RenderedSentence[]> {
    const out: RenderedSentence[] = [];
    for (let i = 0; i < script.sentences.length; i++) {
      const s = script.sentences[i]!;
      onProgress?.(i, script.sentences.length);
      const samples = await this.renderSentence(s.text, settings, dictionary);
      // A paragraph break replaces the sentence gap rather than adding to it —
      // two silences end to end is how a "0.6 s paragraph" becomes 0.68.
      const gap = i === script.sentences.length - 1 ? 0
        : (s.endsParagraph ? settings.paragraphGap : settings.sentenceGap);
      const seconds = samples.length / this.sampleRate;
      const words = s.text.split(/\s+/).filter(Boolean).length;
      let peak = 0; for (const v of samples) peak = Math.max(peak, Math.abs(v));
      out.push({
        id: s.id, text: s.text, samples, trailingGap: gap, seconds,
        peakDBFS: peak > 0 ? 20 * Math.log10(peak) : -Infinity,
        wordsPerMinute: seconds > 0 ? (words / seconds) * 60 : 0,
      });
    }
    return out;
  }

  assemble(rendered: RenderedSentence[]): Float32Array {
    const total = rendered.reduce(
      (n, r) => n + r.samples.length + Math.round(r.trailingGap * this.sampleRate), 0);
    const out = new Float32Array(total);
    let at = 0;
    for (const r of rendered) {
      out.set(r.samples, at);
      at += r.samples.length + Math.round(r.trailingGap * this.sampleRate);
    }
    return out;
  }
}
