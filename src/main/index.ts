import { app, BrowserWindow, ipcMain, dialog, shell } from "electron";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { readFileSync, writeFileSync, copyFileSync, existsSync, rmSync } from "fs";
import { VoiceEngine, type RenderedSentence } from "./engine.js";
import { parseScript } from "../core/script.js";
import { defaultSettings, type SynthesisSettings } from "../core/settings.js";
import { effectiveEntries, checkPronunciation, isBlocking, entryKey,
         type PronunciationEntry } from "../core/pronunciation.js";
import { voicesDir, sessionFile, pronunciationFile, ensureDirs } from "../core/paths.js";
import { voiceNameFromModelFile, configFileFor, rejectionMessage } from "../core/voiceLibrary.js";
import { integratedLUFS, truePeakDBTP } from "../core/loudness.js";
import { writeWav, resample } from "./audio.js";

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = join(here, "..", "..");
const resources = app.isPackaged
  ? join(process.resourcesPath, "app-resources")
  : join(appRoot, "resources");

/**
 * **Nothing here talks to the network, and this is where that is enforced.**
 *
 * Electron itself starts nothing: there is no auto-updater unless one is added,
 * and `crashReporter` only runs if it is started. What does reach out on its
 * own is Chromium — the field-trial "variations" fetch, domain reliability
 * reporting, the component updater, DNS prefetch and network prediction. Each
 * is switched off explicitly rather than assumed absent, because the promise
 * this app makes about not phoning home should be enforced in code somebody can
 * read, not asserted in a README.
 *
 * It is also checked: `npm run netcheck` runs the app behind a request log and
 * fails if anything at all goes out.
 */
function refuseToPhoneHome(): void {
  app.commandLine.appendSwitch("disable-features",
    [
      "ChromeVariations",          // the field-trial seed fetch
      "DomainReliability",         // failure reporting to Google
      "AutofillServerCommunication",
      "OptimizationHints",
      "MediaRouter",
      "Reporting",
      "CrashpadReportUpload",
    ].join(","));
  app.commandLine.appendSwitch("disable-domain-reliability");
  app.commandLine.appendSwitch("disable-component-update");
  app.commandLine.appendSwitch("disable-background-networking");
  app.commandLine.appendSwitch("disable-breakpad");
  app.commandLine.appendSwitch("no-pings");
  app.commandLine.appendSwitch("dns-prefetch-disable");
  app.commandLine.appendSwitch("disable-sync");
  app.commandLine.appendSwitch("metrics-recording-only");
}
refuseToPhoneHome();

let win: BrowserWindow | null = null;
const engines = new Map<string, VoiceEngine>();
let lastRendered: RenderedSentence[] = [];

async function engineFor(voice: string): Promise<VoiceEngine> {
  const cached = engines.get(voice);
  if (cached) return cached;
  const profile = VoiceEngine.availableVoices(resources).find(v => v.name === voice);
  if (!profile) throw new Error(`no voice named ${voice}`);
  const e = await VoiceEngine.open(profile, resources);
  engines.set(voice, e);
  return e;
}

function createWindow(): void {
  win = new BrowserWindow({
    width: 1240, height: 840, minWidth: 940, minHeight: 620,
    backgroundColor: "#272822",
    title: "Voice Forge",
    // A quiet titlebar on every platform. macOS gets the inset traffic lights;
    // Windows and Linux keep their own controls, drawn by the system.
    titleBarStyle: process.platform === "darwin" ? "hiddenInset" : "default",
    webPreferences: {
      preload: join(appRoot, "electron", "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      // No devtools shortcut in a packaged build, and no remote content ever.
      devTools: !app.isPackaged,
      spellcheck: false,
    },
  });
  win.setMenuBarVisibility(false);
  void win.loadFile(join(here, "..", "renderer", "index.html"));

  // Refuse navigation and new windows outright. The page is local and stays
  // local; a link that tries to leave opens in the real browser instead.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith("https://")) void shell.openExternal(url);
    return { action: "deny" };
  });
  win.webContents.on("will-navigate", e => e.preventDefault());

  // Renderer faults reach the terminal. Without this a thrown error in the
  // page is invisible outside devtools -- the window just sits there looking
  // like it worked.
  win.webContents.on("console-message", (_e, level, message, line, source) => {
    if (level >= 2) console.error(`[page] ${source}:${line} ${message}`);
  });
  win.webContents.on("render-process-gone", (_e, d) => console.error("[page] gone:", d.reason));
}

app.whenReady().then(() => {
  ensureDirs();
  createWindow();
  app.on("activate", () => { if (!BrowserWindow.getAllWindows().length) createWindow(); });
});
app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });

// ------------------------------------------------------------------ state
interface Saved {
  text: string; voice: string;
  settings: SynthesisSettings;
  exportSettings: { sampleRate: number; depth: 16 | 24; targetLUFS: number | null; truePeakCeiling: number };
  appearance: "system" | "light" | "dark";
  projectEntries: PronunciationEntry[];
  calibrations: Record<string, unknown>;
}

const readJSON = <T,>(path: string, fallback: T): T => {
  try { return JSON.parse(readFileSync(path, "utf8")) as T; } catch { return fallback; }
};

ipcMain.handle("state:load", () => {
  const saved = readJSON<Partial<Saved>>(sessionFile(), {});
  const globals = readJSON<PronunciationEntry[]>(pronunciationFile(), []);
  return {
    ...saved,
    settings: { ...defaultSettings(), ...(saved.settings ?? {}) },
    entries: [...globals, ...(saved.projectEntries ?? [])],
  };
});

ipcMain.handle("state:save", (_e, s: Saved & { entries: PronunciationEntry[] }) => {
  ensureDirs();
  const entries = s.entries ?? [];
  const { entries: _drop, ...rest } = s;
  // Global entries live in their own file: they belong to the person, not to
  // this script, and writing them into the session would make a copy per
  // script that then drifts.
  writeFileSync(sessionFile(),
    JSON.stringify({ ...rest, projectEntries: entries.filter(e => e.scope === "project") }, null, 2));
  writeFileSync(pronunciationFile(),
    JSON.stringify(entries.filter(e => e.scope === "global"), null, 2));
  return true;
});

// ----------------------------------------------------------------- voices
ipcMain.handle("voices:list", () => ({
  voices: VoiceEngine.availableVoices(resources),
  rejected: VoiceEngine.installedProfiles().rejected.map(rejectionMessage),
}));

ipcMain.handle("voices:install", async () => {
  const r = await dialog.showOpenDialog(win!, {
    title: "Add a voice",
    message: "Choose the .onnx model. Its .onnx.json must be beside it.",
    filters: [{ name: "Piper voice", extensions: ["onnx"] }],
    properties: ["openFile"],
  });
  if (r.canceled || !r.filePaths[0]) return null;
  const modelPath = r.filePaths[0];
  const model = modelPath.split(/[\\/]/).pop()!;
  const name = voiceNameFromModelFile(model);
  if (!name) return { error: `${model} is not a .onnx model file.` };
  const configPath = join(dirname(modelPath), configFileFor(model));
  if (!existsSync(configPath)) {
    return { error: `${model} has no ${configFileFor(model)} beside it. Piper exports the two together — copy both.` };
  }
  ensureDirs();
  try {
    copyFileSync(modelPath, join(voicesDir(), model));
    copyFileSync(configPath, join(voicesDir(), configFileFor(model)));
  } catch (e) { return { error: `Could not copy the voice: ${(e as Error).message}` }; }
  engines.delete(name);
  return { name };
});

ipcMain.handle("voices:remove", (_e, name: string) => {
  const p = VoiceEngine.availableVoices(resources).find(v => v.name === name);
  if (!p || p.isBundled) return false;
  try { rmSync(p.modelPath); rmSync(p.configPath); } catch { /* already gone */ }
  engines.delete(name);
  return true;
});

ipcMain.handle("voices:folder", () => { ensureDirs(); void shell.openPath(voicesDir()); });
ipcMain.handle("app:training", () => {
  const guide = join(resources, "..", "TRAINING.md");
  void shell.openPath(existsSync(guide) ? guide : join(appRoot, "TRAINING.md"));
});

ipcMain.handle("voice:vocabulary", async (_e, voice: string) =>
  [...(await engineFor(voice)).vocabulary]);
ipcMain.handle("voice:defaultPhonemes", async (_e, voice: string, word: string) =>
  (await engineFor(voice)).defaultPhonemes(word));

// ----------------------------------------------------------------- render
interface RenderRequest {
  text: string; voice: string;
  settings: SynthesisSettings;
  entries: PronunciationEntry[];
}

/** Only entries that pass validation reach the model. A warning does not
 * block — a look-alike is legal IPA and somebody may mean it. */
async function usableEntries(req: RenderRequest): Promise<PronunciationEntry[]> {
  const vocab = (await engineFor(req.voice)).vocabulary;
  return effectiveEntries(req.entries)
    .filter(e => !isBlocking(checkPronunciation(e.ipa, vocab)));
}

ipcMain.handle("render", async (_e, req: RenderRequest) => {
  const engine = await engineFor(req.voice);
  const script = parseScript(req.text);
  const dict = await usableEntries(req);
  lastRendered = await engine.render(script, req.settings, dict,
    (done, total) => win?.webContents.send("progress", done / total));
  const audio = engine.assemble(lastRendered);
  return {
    sentences: lastRendered.map(({ samples, ...rest }) => rest),
    sampleRate: engine.sampleRate,
    wav: writeWav(audio, engine.sampleRate, 16).buffer,
    lufs: integratedLUFS(audio, engine.sampleRate),
    truePeak: truePeakDBTP(audio, engine.sampleRate),
  };
});

ipcMain.handle("render:one", async (_e, req: RenderRequest & { id: number }) => {
  const engine = await engineFor(req.voice);
  const index = lastRendered.findIndex(r => r.id === req.id);
  if (index < 0) return null;
  const old = lastRendered[index]!;
  const samples = await engine.renderSentence(old.text, req.settings, await usableEntries(req));
  const seconds = samples.length / engine.sampleRate;
  const words = old.text.split(/\s+/).filter(Boolean).length;
  let peak = 0; for (const v of samples) peak = Math.max(peak, Math.abs(v));
  lastRendered[index] = { ...old, samples, seconds,
    peakDBFS: peak > 0 ? 20 * Math.log10(peak) : -Infinity,
    wordsPerMinute: seconds > 0 ? (words / seconds) * 60 : 0 };
  const audio = engine.assemble(lastRendered);
  return {
    sentences: lastRendered.map(({ samples: _s, ...rest }) => rest),
    wav: writeWav(audio, engine.sampleRate, 16).buffer,
    lufs: integratedLUFS(audio, engine.sampleRate),
    truePeak: truePeakDBTP(audio, engine.sampleRate),
  };
});

/** Which sentences an entry actually changes — run, not guessed at, because
 * the whole question is whether espeak said the same thing here as it did for
 * the word alone. */
ipcMain.handle("dictionary:report", async (_e, req: RenderRequest & { entry: PronunciationEntry }) => {
  const engine = await engineFor(req.voice);
  const script = parseScript(req.text);
  let applied = 0, mentions = 0;
  for (const s of script.sentences) {
    if (s.text.toLowerCase().includes(entryKey(req.entry))) mentions += 1;
    const r = await engine.phonemesFor(s.text, req.settings, [req.entry]);
    if (r.applied.has(entryKey(req.entry))) applied += 1;
  }
  return { applied, mentions };
});

// -------------------------------------------------------------- calibrate
/**
 * What each punctuation mark is actually worth, for this voice at these
 * settings.
 *
 * **By total duration, not by looking for the gap.** The obvious method was
 * tried and does not work, for two reasons that are worth keeping: the model
 * has no silence to find — its pauses sit around 0.005–0.01 amplitude, so a
 * threshold of 0.002 reported an 11 ms comma where 0.01 reported 434 ms on the
 * same line — and the model is stochastic, so one draw measures nothing.
 * Successive draws at 0, 4, 8 and 12 clause pads gave gaps of 434, 213, 300 and
 * 265 ms, no trend at all, while the totals went 3.29, 3.27, 3.48, 3.69 s.
 *
 * So: render the same words with and without the mark and subtract the
 * durations, with `noiseW` forced to zero so the duration predictor is
 * repeatable. Nothing has to be located and no threshold is involved.
 */
const probeBodies: [string, string][] = [
  ["The room was quiet", "and nobody moved"],
  ["She looked up", "then looked away"],
  ["It arrived on Tuesday", "which was too late"],
  ["Take the first turning", "then keep going"],
  ["He said nothing", "and that was answer enough"],
  ["The light changed", "so we crossed"],
];

ipcMain.handle("calibrate", async (_e, req: RenderRequest) => {
  const engine = await engineFor(req.voice);
  const deterministic = { ...req.settings, noiseW: 0, clausePads: 0 };
  const duration = async (text: string, s: SynthesisSettings) =>
    (await engine.renderSentence(text, s)).length / engine.sampleRate;

  const marks = [",", ";", ":", "\u2014"];
  const out: { mark: string; mean: number; minimum: number; maximum: number; samples: number }[] = [];
  let step = 0;
  const total = marks.length * probeBodies.length * 2 + 4;

  for (const mark of marks) {
    const deltas: number[] = [];
    for (const [a, b] of probeBodies) {
      const withMark = await duration(`${a}${mark} ${b}.`, deterministic);
      win?.webContents.send("progress", ++step / total);
      const without = await duration(`${a} ${b}.`, deterministic);
      win?.webContents.send("progress", ++step / total);
      deltas.push(Math.max(0, withMark - without));
    }
    out.push({
      mark, samples: deltas.length,
      mean: deltas.reduce((x, y) => x + y, 0) / deltas.length,
      minimum: Math.min(...deltas), maximum: Math.max(...deltas),
    });
  }

  // What one clause pad buys, from the slope across the range rather than one
  // endpoint pair — a single difference would ride on whatever the duration
  // predictor happened to do at that count.
  const probe = `${probeBodies[0]![0]}, ${probeBodies[0]![1]}.`;
  const base = await duration(probe, deterministic);
  const slopes: number[] = [];
  for (const pads of [4, 8, 12]) {
    const d = await duration(probe, { ...deterministic, clausePads: pads });
    slopes.push((d - base) / pads);
    win?.webContents.send("progress", ++step / total);
  }
  return {
    voice: req.voice, lengthScale: req.settings.lengthScale, marks: out,
    secondsPerClausePad: Math.max(0, slopes.reduce((a, b) => a + b, 0) / slopes.length),
  };
});

// ----------------------------------------------------------------- export
ipcMain.handle("export", async (_e, req: {
  sampleRate: number; depth: 16 | 24; targetLUFS: number | null; truePeakCeiling: number;
}) => {
  if (!lastRendered.length) return { error: "Nothing rendered yet." };
  const engine = [...engines.values()][0];
  if (!engine) return { error: "No voice loaded." };
  const r = await dialog.showSaveDialog(win!, {
    title: "Export", defaultPath: "voiceover.wav",
    filters: [{ name: "WAV", extensions: ["wav"] }],
  });
  if (r.canceled || !r.filePath) return null;

  // Resample first, then measure, then gain. Loudness and true peak both move
  // with sample rate, so measuring at the model's rate and applying the answer
  // to a 48 kHz file reports a number the file does not have.
  let audio = resample(engine.assemble(lastRendered), engine.sampleRate, req.sampleRate);
  const before = integratedLUFS(audio, req.sampleRate);
  let gainDB = 0, heldBack = false;
  if (req.targetLUFS != null && isFinite(before)) {
    gainDB = req.targetLUFS - before;
    const peak = truePeakDBTP(audio, req.sampleRate);
    if (peak + gainDB > req.truePeakCeiling) { gainDB = req.truePeakCeiling - peak; heldBack = true; }
  }
  let clipped = 0;
  if (gainDB !== 0) {
    const g = Math.pow(10, gainDB / 20);
    audio = Float32Array.from(audio, v => {
      const x = v * g;
      if (x > 1 || x < -1) clipped += 1;
      return Math.max(-1, Math.min(1, x));
    });
  }
  writeFileSync(r.filePath, writeWav(audio, req.sampleRate, req.depth));
  return {
    path: r.filePath,
    seconds: audio.length / req.sampleRate,
    sampleRate: req.sampleRate, depth: req.depth,
    lufsBefore: before, lufsAfter: integratedLUFS(audio, req.sampleRate),
    truePeakAfter: truePeakDBTP(audio, req.sampleRate),
    gainApplied: gainDB, clipped, heldBack,
  };
});
