/**
 * `piper-phonemize` ships no types. The surface this app uses is three
 * functions, and the one that matters is `initialize`.
 *
 * **espeak wants the *parent* of `espeak-ng-data` and appends the directory
 * name itself.** Getting that wrong fails open, not loud: the package
 * auto-initializes with its own bundled data, which is a newer espeak-ng whose
 * en-us rules moved the NORTH/FORCE vowel from `ɔːɹ` to `oːɹ`. The app would
 * still run and still speak — just not the way the model was trained, in
 * *four, before, more, door, course, report* and every word like them.
 */
declare module "piper-phonemize" {
  /** Point espeak at a data directory. Pass the parent of `espeak-ng-data`.
   * Must be called before `phonemize`, or bundled data is used instead. */
  export function initialize(dataDir: string): void;
  /** Returns one array of Unicode codepoints per clause. */
  export function phonemize(text: string, voice?: string): number[][];
  export function phonemizeToString(text: string, voice?: string): string;
  export function version(): string;
}
