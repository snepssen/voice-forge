/**
 * Where a voice came from and whether it is complete.
 *
 * One voice ships with the app. Everything else is the listener's own. The
 * bundled one is not privileged beyond being present: it loads by the same
 * path, is validated by the same rules, and can be hidden behind a better one.
 */
export interface VoiceProfile {
  name: string;
  modelPath: string;
  configPath: string;
  isBundled: boolean;
}

export type VoiceRejection =
  | { kind: "missingConfig"; model: string }
  | { kind: "missingModel"; config: string };

export function rejectionMessage(r: VoiceRejection): string {
  return r.kind === "missingConfig"
    ? `${r.model} has no matching .onnx.json beside it. Piper exports the two together; copy both.`
    : `${r.config} has no matching .onnx beside it. Copy the model file too.`;
}

/**
 * Piper's own naming, which is what an exported voice already has:
 * `<locale>-<name>-<quality>.onnx`. Kept permissive on purpose — a voice
 * somebody trained might be `en_GB-alice-high`, and refusing it for not being
 * `en_US`/`medium` would reject good models to enforce a convention this app
 * has no stake in.
 */
export function voiceNameFromModelFile(file: string): string | null {
  if (!file.endsWith(".onnx")) return null;
  const stem = file.slice(0, -".onnx".length);
  const parts = stem.split("-");
  if (parts.length < 3) return stem || null;
  return parts.slice(1, -1).join("-");
}

export const configFileFor = (modelFile: string) => `${modelFile}.json`;

/** Sort a directory listing into voices and complaints. */
export function scanVoices(files: string[], dir: string, bundled: boolean):
  { voices: VoiceProfile[]; rejected: VoiceRejection[] } {
  const present = new Set(files);
  const voices: VoiceProfile[] = [];
  const rejected: VoiceRejection[] = [];
  const sep = process.platform === "win32" ? "\\" : "/";

  for (const file of [...files].sort()) {
    if (!file.endsWith(".onnx")) continue;
    const name = voiceNameFromModelFile(file);
    if (!name) continue;
    const config = configFileFor(file);
    if (!present.has(config)) { rejected.push({ kind: "missingConfig", model: file }); continue; }
    voices.push({ name, modelPath: dir + sep + file, configPath: dir + sep + config, isBundled: bundled });
  }
  for (const file of [...files].sort()) {
    if (!file.endsWith(".onnx.json")) continue;
    const model = file.slice(0, -".json".length);
    if (!present.has(model)) rejected.push({ kind: "missingModel", config: file });
  }
  return { voices, rejected };
}

/**
 * Merge bundled and installed voices.
 *
 * **An installed voice of the same name wins.** That is what makes the bundled
 * voice unprivileged: somebody who retrains `snepssen` and drops it in gets
 * their version, without having to pick a different name to escape ours.
 */
export function mergeVoices(bundled: VoiceProfile[], installed: VoiceProfile[]): VoiceProfile[] {
  const byName = new Map<string, VoiceProfile>();
  for (const v of bundled) byName.set(v.name, v);
  for (const v of installed) byName.set(v.name, v);
  return [...byName.values()].sort((a, b) => a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1);
}
