/**
 * The window.
 *
 * Everything the Mac build shows, drawn the same way and saying the same
 * things. The renderer holds no engine and no filesystem: it asks the main
 * process for work over a fixed list of named requests and renders the answer.
 */
import { parseScript, wordCount, currencies, spokenCurrency, type Script } from "../core/script.js";
import { defaultSettings, ranges, type SynthesisSettings } from "../core/settings.js";
import { paceNote, noteFor } from "../core/voiceNotes.js";
import { loudnessTargets } from "../core/loudness.js";
import * as P from "../core/pronunciation.js";

// The bridge, as exposed by the preload.
declare global {
  interface Window { vf: Record<string, (...a: any[]) => Promise<any>> & { onProgress(fn: (p: number) => void): void } }
}
const vf = window.vf;
const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const el = (tag: string, cls?: string, text?: string) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
};

interface SentenceInfo {
  id: number; text: string; trailingGap: number; seconds: number;
  peakDBFS: number; wordsPerMinute: number;
}

const state = {
  text: "", voice: "",
  settings: defaultSettings(),
  exportSettings: { sampleRate: 48000, depth: 16 as 16 | 24, targetLUFS: -14 as number | null, truePeakCeiling: -1 },
  appearance: "system" as "system" | "light" | "dark",
  entries: [] as P.PronunciationEntry[],
  voices: [] as { name: string; isBundled: boolean }[],
  rejected: [] as string[],
  sampleRate: 22050,
  rendered: [] as SentenceInfo[],
  lufs: -Infinity, truePeak: -Infinity,
  selected: null as number | null,
  vocabulary: new Set<string>(),
  defaults: new Map<string, string>(),
  applyReports: new Map<string, { applied: number; mentions: number }>(),
  calibration: null as { marks: { mark: string; mean: number }[]; secondsPerClausePad: number } | null,
  busy: null as string | null,
  error: null as string | null,
  receipt: null as any,
};

const script = (): Script => parseScript(state.text);
const audioEl = $("player") as HTMLAudioElement;
let blobUrl: string | null = null;

// ------------------------------------------------------------------- theme
function applyAppearance() {
  const dark = state.appearance === "dark"
    || (state.appearance === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset["theme"] = dark ? "dark" : "light";
  for (const b of $("appearance").querySelectorAll("button")) {
    b.setAttribute("aria-pressed", String((b as HTMLElement).dataset["v"] === state.appearance));
  }
}
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", applyAppearance);

// ------------------------------------------------------------------- dials
interface DialSpec {
  key: keyof SynthesisSettings; label: string; step: number;
  format: (v: number) => string; note: () => string; reference?: number;
}

function dial(spec: DialSpec): HTMLElement {
  const [lo, hi] = ranges[spec.key as keyof typeof ranges];
  const v = state.settings[spec.key] as number;
  const wrap = el("div", "dial");
  const row = el("div", "row");
  row.append(el("span", undefined, spec.label));
  const val = el("span", "val", spec.format(v));
  const atRef = spec.reference != null && Math.abs(v - spec.reference) < spec.step / 2;
  if (atRef) val.classList.add("ref");
  row.append(val);
  if (spec.reference != null && !atRef) {
    const revert = el("button", "revert", "↺") as HTMLButtonElement;
    revert.title = "Back to the voice's own value";
    revert.onclick = () => { (state.settings[spec.key] as number) = spec.reference!; changed(); };
    row.append(revert);
  }
  const slider = el("input") as HTMLInputElement;
  Object.assign(slider, { type: "range", min: String(lo), max: String(hi), step: String(spec.step), value: String(v) });
  slider.oninput = () => { (state.settings[spec.key] as number) = Number(slider.value); changed(); };
  wrap.append(row, slider, el("p", "note", spec.note()));
  return wrap;
}

const secs = (v: number) => `${v.toFixed(2)} s`;

function renderDials() {
  const pauses = $("pauseDials"); pauses.replaceChildren(
    dial({ key: "sentenceGap", label: "Between sentences", step: 0.01, format: secs, reference: 0.08,
           note: () => "Real silence laid between two calls to the model. Exact." }),
    dial({ key: "paragraphGap", label: "At a paragraph", step: 0.05, format: secs, reference: 0.55,
           note: () => "Replaces the sentence gap at a blank line rather than adding to it." }));

  $("modelDials").replaceChildren(
    dial({ key: "lengthScale", label: "Pace", step: 0.01, format: v => v.toFixed(2), reference: 1.0,
           note: () => paceNote(state.voice, state.settings.lengthScale) }),
    dial({ key: "noiseScale", label: "Variation", step: 0.01, format: v => v.toFixed(3), reference: 0.667,
           note: () => "How much the sound differs between takes. Not pace, and not pausing." }),
    dial({ key: "noiseW", label: "Cadence variation", step: 0.01, format: v => v.toFixed(2), reference: 0.8,
           note: () => "How much the rhythm differs between takes. At zero, two takes of a line are near-identical — repeatable, and noticeably mechanical." }));

  $("clausePadsVal").textContent = String(state.settings.clausePads);
  $("trailingPadsVal").textContent = String(state.settings.trailingPads);
  ($("dropFinalFullStop") as HTMLInputElement).checked = state.settings.dropFinalFullStop;
  ($("spokenCurrency") as HTMLInputElement).checked = state.settings.spokenCurrency;
  $("clauseNote").textContent = clauseNote();
  $("currencyNote").textContent = currencyNote();
}

function clauseNote(): string {
  const cal = state.calibration;
  if (!cal) return "Padding phonemes given to the model at , ; : and —. Measure the voice to see what they buy.";
  const comma = cal.marks.find(m => m.mark === ",");
  if (!comma) return "Measured, but no comma in the probe set.";
  const added = state.settings.clausePads * cal.secondsPerClausePad;
  return state.settings.clausePads === 0
    ? `about ${Math.round(comma.mean * 1000)} ms, as the model writes it`
    : `about ${Math.round((comma.mean + added) * 1000)} ms`;
}

/** Shown with a live example from the script where there is one, because this
 * is the only setting that changes the words. */
function currencyNote(): string {
  if (!state.settings.spokenCurrency) {
    return "Off: espeak reads the symbol first — $4.99 becomes “dollar four point nine nine”, and every currency does the same.";
  }
  const found = script().sentences.map(s => s.text)
    .find(t => currencies.some(c => t.includes(c.symbol)));
  if (found) {
    const at = Math.min(...currencies.map(c => { const i = found.indexOf(c.symbol); return i < 0 ? 1e9 : i; }));
    const words = found.slice(at).split(" ").slice(0, 2).join(" ");
    return `“${words}” → “${spokenCurrency(words)}”. The only setting here that changes your words.`;
  }
  return "$4.99 is read “4 dollars 99”, not “dollar four point nine nine”. The only setting here that changes your words.";
}

// ------------------------------------------------------------------ voices
function renderVoices() {
  const picker = $("voicePicker");
  picker.replaceChildren(...state.voices.map(v => {
    const b = el("button", undefined, v.name) as HTMLButtonElement;
    b.setAttribute("aria-pressed", String(v.name === state.voice));
    b.onclick = () => { state.voice = v.name; void voiceChanged(); };
    return b;
  }));
  const note = noteFor(state.voice);
  $("voiceNote").textContent = note?.summary
    ?? "Installed by you. Nothing here has measured it — press Measure this voice to learn its pauses.";
  $("voiceRate").textContent = state.voices.length ? `${state.sampleRate} Hz` : "";

  $("voiceRejects").replaceChildren(...state.rejected.map(m => el("p", "note warn", m)));

  // Every installed voice gets its own row and its own removal, not only the
  // selected one: managing a thing you are not currently using is the whole
  // point of managing it.
  const installed = state.voices.filter(v => !v.isBundled);
  $("installedVoices").replaceChildren(...installed.map(v => {
    const row = el("div", "sentence");
    const top = el("div", "top");
    top.append(el("span", "text", v.name), el("span", "secs", "installed"));
    const trash = el("button", "iconbtn", "🗑") as HTMLButtonElement;
    trash.onclick = async () => {
      // Confirmed, because the files being deleted may be days of training
      // that exist nowhere else.
      if (!confirm(`Remove ${v.name}?\n\nIts model and config are deleted from the voices folder. If they exist nowhere else, that is days of training gone.`)) return;
      await vf["removeVoice"]!(v.name);
      await loadVoices();
    };
    top.append(trash);
    row.append(top);
    return row;
  }));
}

async function loadVoices() {
  const r = await vf["listVoices"]!();
  state.voices = r.voices; state.rejected = r.rejected;
  if (!state.voices.some(v => v.name === state.voice)) state.voice = state.voices[0]?.name ?? "";
  await voiceChanged();
}

async function voiceChanged() {
  if (!state.voice) { renderVoices(); return; }
  state.vocabulary = new Set<string>(await vf["vocabulary"]!(state.voice));
  state.defaults.clear();
  state.calibration = null;
  renderVoices(); renderDials(); save();
}

// ------------------------------------------------------------------- take
function renderTake() {
  const panel = $("takePanel");
  if (!state.rendered.length) { panel.hidden = true; return; }
  panel.hidden = false;

  const total = state.rendered.reduce((n, r) => n + r.seconds + r.trailingGap, 0);
  const speech = state.rendered.reduce((n, r) => n + r.seconds, 0);
  const words = wordCount(script());
  const wpm = total > 0 ? (words / total) * 60 : 0;
  const paceHint = wpm > 185 ? "a fast read; 150 is typical"
    : wpm < 120 ? "a slow read; 150 is typical" : "around the usual 150";

  const stat = (v: string, k: string, sub?: string) => {
    const n = el("div", "stat");
    n.append(el("div", "v", v), el("div", "k", k));
    if (sub) n.append(el("div", "k", sub));
    return n;
  };
  $("takeStats").replaceChildren(
    stat(`${total.toFixed(1)}s`, "length"),
    stat(`${speech.toFixed(1)}s`, "speech"),
    stat(`${(total - speech).toFixed(1)}s`, "silence"),
    stat(`${Math.round(wpm)} wpm`, "pace", paceHint),
    stat(isFinite(state.lufs) ? `${state.lufs.toFixed(1)} LUFS` : "—", "loudness", "at the model's rate"));
  $("takeTrailing").textContent = total > 0
    ? `${Math.round(((total - speech) / total) * 100)}% of it is silence` : "";

  $("sentences").replaceChildren(...state.rendered.map(r => {
    const row = el("div", "sentence");
    row.dataset["selected"] = String(state.selected === r.id);
    const top = el("div", "top");
    top.append(el("span", "text", r.text), el("span", "secs", `${r.seconds.toFixed(2)}s`));
    row.append(top);
    row.onclick = () => { state.selected = state.selected === r.id ? null : r.id; renderTake(); };
    if (state.selected === r.id) {
      const d = el("div", "detail");
      d.append(el("span", undefined, `${Math.round(r.wordsPerMinute)} wpm`),
               el("span", undefined, `peak ${r.peakDBFS.toFixed(1)} dBFS`));
      if (r.trailingGap > 0) d.append(el("span", undefined, `+${r.trailingGap.toFixed(2)}s gap`));
      d.append(el("span", "grow"));
      const reroll = el("button", undefined, "Re-roll") as HTMLButtonElement;
      reroll.title = "Render this sentence again. The model is stochastic, so it is a different take.";
      reroll.onclick = async ev => {
        ev.stopPropagation();
        await withBusy("Re-rolling", async () => {
          const res = await vf["renderOne"]!({ ...request(), id: r.id });
          if (res) applyRenderResult(res);
        });
      };
      d.append(reroll);
      row.append(d);
    }
    return row;
  }));
}

// ----------------------------------------------------------------- export
function renderExport() {
  const sel = $("exLufs") as HTMLSelectElement;
  if (!sel.options.length) {
    for (const t of loudnessTargets) {
      const o = document.createElement("option");
      o.value = String(t.lufs); o.textContent = t.name;
      sel.append(o);
    }
  }
  sel.value = String(state.exportSettings.targetLUFS ?? NaN);
  ($("exRate") as HTMLSelectElement).value = String(state.exportSettings.sampleRate);
  ($("exDepth") as HTMLSelectElement).value = String(state.exportSettings.depth);
  $("depthNote").textContent = state.exportSettings.depth === 16
    ? "What a video editor expects. Fine for a finished voiceover."
    : "More headroom for further editing. Twice the file size for the same length.";
  const target = loudnessTargets.find(t =>
    (isNaN(t.lufs) && state.exportSettings.targetLUFS == null) || t.lufs === state.exportSettings.targetLUFS);
  $("lufsNote").textContent = target?.note ?? "";

  // What exporting will do, before it does it. A dry voice sits near -24 LUFS
  // with peaks around -6 dBFS, so reaching -14 wants gain the true-peak ceiling
  // will not allow — and finding that out afterwards is the wrong order.
  const box = $("exportPreview"); box.replaceChildren();
  if (state.rendered.length && isFinite(state.lufs)) {
    const wanted = state.exportSettings.targetLUFS == null ? 0 : state.exportSettings.targetLUFS - state.lufs;
    const possible = state.exportSettings.targetLUFS == null ? 0
      : Math.min(wanted, state.exportSettings.truePeakCeiling - state.truePeak);
    const held = possible < wanted - 0.01;
    box.append(el("div", "divider"));
    const stats = el("div", "stats");
    const s = (v: string, k: string) => { const n = el("div", "stat"); n.append(el("div", "v", v), el("div", "k", k)); return n; };
    stats.append(s(`${state.lufs.toFixed(1)} LUFS`, "as rendered"),
                 s(`${state.truePeak.toFixed(1)} dBTP`, "true peak"),
                 s(`${(state.lufs + possible).toFixed(1)} LUFS`, "on export"));
    box.append(stats);
    box.append(el("p", held ? "note warn" : "note good", held
      ? `${(wanted - possible).toFixed(1)} dB short of the target: the true-peak ceiling stops the gain first. A dry voice with hard consonants and real silences cannot reach a streaming target on gain alone — that needs compression, which this app does not do. The file will be correct, just quieter.`
      : state.exportSettings.targetLUFS == null ? "Exported at the level the model produced." : "The target is reachable on gain alone."));
  }

  const rec = $("exportReceipt"); rec.replaceChildren();
  const r = state.receipt;
  if (r) {
    rec.append(el("div", "divider"), el("div", undefined, r.path.split(/[\\/]/).pop()));
    rec.append(el("p", "note",
      `${r.seconds.toFixed(1)}s · ${(r.sampleRate / 1000).toFixed(0)} kHz · ${r.depth}-bit · ${r.lufsAfter.toFixed(1)} LUFS · true peak ${r.truePeakAfter.toFixed(1)} dBTP`));
    if (r.clipped > 0) rec.append(el("p", "note bad", `${r.clipped} samples clipped.`));
  }
}

// ------------------------------------------------------------- dictionary
async function ensureDefault(word: string): Promise<string> {
  const key = word.toLowerCase();
  const hit = state.defaults.get(key);
  if (hit !== undefined) return hit;
  const v = await vf["defaultPhonemes"]!(state.voice, word);
  state.defaults.set(key, v);
  return v;
}

function candidateWords(): string[] {
  const have = new Set(state.entries.map(P.entryKey));
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of state.text.split(/[^\p{L}'’-]+/u)) {
    const key = raw.toLowerCase();
    if (raw.length < 6 || have.has(key) || seen.has(key)) continue;
    seen.add(key); out.push(raw);
  }
  return out.slice(0, 18);
}

async function renderDictionary() {
  const box = $("entries");
  box.replaceChildren(...await Promise.all(state.entries.map(async entry => {
    const row = el("div", "entry");
    row.append(el("span", undefined, entry.word));
    row.append(el("span", "says", await ensureDefault(entry.word)));

    const input = el("input") as HTMLInputElement;
    input.type = "text"; input.value = entry.ipa; input.placeholder = "IPA";
    input.oninput = () => { entry.ipa = input.value; void refreshEntryStatus(entry, row); save(); };
    row.append(input);

    const scope = el("select") as HTMLSelectElement;
    for (const [v, label] of [["global", "Everywhere"], ["project", "This script"]] as const) {
      const o = document.createElement("option"); o.value = v; o.textContent = label; scope.append(o);
    }
    scope.value = entry.scope;
    scope.onchange = () => { entry.scope = scope.value as P.Scope; void renderDictionary(); save(); };
    row.append(scope);

    const on = el("input") as HTMLInputElement;
    on.type = "checkbox"; on.checked = entry.enabled;
    on.title = "Off keeps the entry without applying it.";
    on.onchange = () => { entry.enabled = on.checked; void renderDictionary(); save(); };
    row.append(on);

    const del = el("button", "iconbtn", "🗑") as HTMLButtonElement;
    del.onclick = () => {
      state.entries = state.entries.filter(e => e.id !== entry.id);
      void renderDictionary(); save();
    };
    row.append(del);

    row.append(el("span", "status"));
    void refreshEntryStatus(entry, row);
    return row;
  })));

  const chips = candidateWords();
  const s = $("suggest"); s.replaceChildren();
  if (chips.length) {
    s.append(el("p", "note", "From your script"));
    for (const w of chips) {
      const c = el("button", "chip", w) as HTMLButtonElement;
      c.onclick = async () => { await addEntry(w); };
      s.append(c);
    }
    s.append(el("p", "note", "Longer and less common words, which is where espeak is likeliest to guess. Hear one before you change it."));
  }
  const g = state.entries.filter(e => e.scope === "global").length;
  $("dictCount").textContent = `${g} everywhere · ${state.entries.length - g} this script`;
}

async function refreshEntryStatus(entry: P.PronunciationEntry, row: HTMLElement) {
  const status = row.querySelector(".status") as HTMLElement;
  const problem = P.checkPronunciation(entry.ipa, state.vocabulary);
  status.className = "status";
  if (entry.ipa && P.isBlocking(problem)) {
    status.classList.add("bad"); status.textContent = `⛔ ${P.problemMessage(problem)}`; return;
  }
  if (P.hasWarning(problem)) {
    status.classList.add("warn"); status.textContent = `⚠ ${P.problemMessage(problem)}`; return;
  }
  if (P.isShadowed(entry, state.entries)) {
    status.classList.add("note");
    status.textContent = "A “this script” entry for the same word is in force, so this one is doing nothing.";
    return;
  }
  if (!entry.ipa || !entry.enabled) { status.textContent = ""; return; }
  // Whether it lands is a fact about the script, not about the entry — and it
  // is the failure this feature exists to prevent.
  const r = await vf["applyReport"]!({ ...request(), entry });
  state.applyReports.set(entry.id, r);
  if (r.mentions === 0) {
    status.classList.add("note");
    status.textContent = "Not in this script. It will apply when the word appears.";
  } else if (r.applied === r.mentions) {
    status.classList.add("good");
    status.textContent = `✓ Applies in ${r.applied} of ${r.mentions} sentence${r.mentions === 1 ? "" : "s"}.`;
  } else {
    status.classList.add("warn");
    status.textContent = `⚠ Applies in ${r.applied} of ${r.mentions} — espeak said something different in the rest, usually because the stress moved.`;
  }
}

async function addEntry(word: string) {
  const key = word.toLowerCase();
  if (state.entries.some(e => P.entryKey(e) === key && e.scope === "global")) return;
  // Seeded with what espeak already says, so the field starts from something
  // correct and editable rather than from nothing.
  state.entries.push({
    id: crypto.randomUUID(), word, ipa: await ensureDefault(word),
    scope: "global", enabled: true,
  });
  await renderDictionary(); save();
}

// ------------------------------------------------------------------ work
const request = () => ({
  text: state.text, voice: state.voice,
  settings: state.settings, entries: state.entries,
});

async function withBusy(label: string, fn: () => Promise<void>) {
  state.busy = label; state.error = null; paint();
  try { await fn(); }
  catch (e) { state.error = (e as Error).message; }
  state.busy = null; paint();
}

function applyRenderResult(res: any) {
  state.rendered = res.sentences;
  state.lufs = res.lufs; state.truePeak = res.truePeak;
  if (res.sampleRate) state.sampleRate = res.sampleRate;
  if (blobUrl) URL.revokeObjectURL(blobUrl);
  blobUrl = URL.createObjectURL(new Blob([res.wav], { type: "audio/wav" }));
  audioEl.src = blobUrl;
  paint();
}

function changed() { renderDials(); renderExport(); save(); }

let saveTimer: ReturnType<typeof setTimeout> | null = null;
function save() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    void vf["saveState"]!({
      text: state.text, voice: state.voice, settings: state.settings,
      exportSettings: state.exportSettings, appearance: state.appearance,
      entries: state.entries, calibrations: {},
    });
  }, 400);
}

function paint() {
  const s = script();
  $("scriptSummary").textContent =
    `${s.sentences.length} sentence${s.sentences.length === 1 ? "" : "s"} · ${wordCount(s)} words`;
  ($("btnRender") as HTMLButtonElement).disabled = !!state.busy || !s.sentences.length;
  ($("btnPlay") as HTMLButtonElement).disabled = !state.rendered.length;
  ($("btnStop") as HTMLButtonElement).disabled = !state.rendered.length;
  ($("btnExport") as HTMLButtonElement).disabled = !state.rendered.length;
  ($("btnRender") as HTMLButtonElement).textContent = state.busy ?? "Render";
  const err = $("errorPanel");
  err.hidden = !state.error;
  err.textContent = state.error ?? "";
  renderDials(); renderTake(); renderExport(); applyAppearance();
}

// ------------------------------------------------------------------- wire
$("script").addEventListener("input", e => {
  state.text = (e.target as HTMLTextAreaElement).value;
  paint();
});
$("btnRender").addEventListener("click", () => withBusy("Rendering", async () => {
  applyRenderResult(await vf["render"]!(request()));
}));
$("btnPlay").addEventListener("click", () => void audioEl.play());
$("btnStop").addEventListener("click", () => { audioEl.pause(); audioEl.currentTime = 0; });
$("btnExport").addEventListener("click", async () => {
  const r = await vf["exportTake"]!(state.exportSettings);
  if (r?.error) { state.error = r.error; } else if (r) { state.receipt = r; }
  paint();
});
$("btnDict").addEventListener("click", async () => {
  $("sheet").dataset["open"] = "true";
  await renderDictionary();
});
$("dictDone").addEventListener("click", () => { $("sheet").dataset["open"] = "false"; paint(); });
$("btnAddWord").addEventListener("click", async () => {
  const input = $("newWord") as HTMLInputElement;
  const w = input.value.trim();
  if (!w) return;
  await addEntry(w); input.value = "";
});
$("btnAddVoice").addEventListener("click", async () => {
  const r = await vf["installVoice"]!();
  if (r?.error) { state.error = r.error; paint(); return; }
  if (r?.name) { state.voice = r.name; await loadVoices(); }
});
$("btnVoicesFolder").addEventListener("click", () => void vf["openVoicesFolder"]!());
$("btnTraining").addEventListener("click", () => void vf["openTraining"]!());
$("btnCalibrate").addEventListener("click", () => withBusy("Measuring", async () => {
  state.calibration = await vf["calibrate"]!(request());
}));
$("appearance").addEventListener("click", e => {
  const v = (e.target as HTMLElement).dataset["v"];
  if (!v) return;
  state.appearance = v as typeof state.appearance;
  applyAppearance(); save();
});
for (const b of document.querySelectorAll<HTMLElement>("[data-step]")) {
  b.addEventListener("click", () => {
    const [key, delta] = b.dataset["step"]!.split(":") as [keyof typeof ranges, string];
    const [lo, hi] = ranges[key];
    const next = (state.settings[key] as number) + Number(delta);
    (state.settings[key] as number) = Math.max(lo, Math.min(hi, next));
    changed();
  });
}
for (const [id, key] of [["dropFinalFullStop", "dropFinalFullStop"], ["spokenCurrency", "spokenCurrency"]] as const) {
  $(id).addEventListener("change", e => {
    (state.settings[key] as boolean) = (e.target as HTMLInputElement).checked;
    changed();
  });
}
$("exRate").addEventListener("change", e => {
  state.exportSettings.sampleRate = Number((e.target as HTMLSelectElement).value); changed();
});
$("exDepth").addEventListener("change", e => {
  state.exportSettings.depth = Number((e.target as HTMLSelectElement).value) as 16 | 24; changed();
});
$("exLufs").addEventListener("change", e => {
  const v = Number((e.target as HTMLSelectElement).value);
  state.exportSettings.targetLUFS = isNaN(v) ? null : v; changed();
});
vf.onProgress(p => { if (state.busy) $("btnRender").textContent = `${state.busy} ${Math.round(p * 100)}%`; });

// ------------------------------------------------------------------ start
(async () => {
  if (navigator.userAgent.includes("Mac")) document.body.dataset["mac"] = "true";
  const saved = await vf["loadState"]!();
  state.text = saved.text ?? `Welcome back to the channel. Today we are looking at something a little different.

I have been building a text to speech tool, and the interesting part is not the voice — it is the timing. A comma is worth about half a second here, which is longer than most people expect.`;
  if (saved.settings) state.settings = saved.settings;
  if (saved.exportSettings) state.exportSettings = saved.exportSettings;
  if (saved.appearance) state.appearance = saved.appearance;
  if (saved.entries) state.entries = saved.entries;
  if (saved.voice) state.voice = saved.voice;
  ($("script") as HTMLTextAreaElement).value = state.text;
  await loadVoices();
  paint();
})();
