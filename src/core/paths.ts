import { homedir } from "os";
import { join } from "path";
import { mkdirSync } from "fs";

/**
 * Where this app keeps things, on each platform it runs on.
 *
 * Each platform's own convention, honoured explicitly: Electron's `app.getPath`
 * would do most of this, but the core must stay usable from the check runner
 * and from `node` without an Electron instance, and a path helper that only
 * works inside the app is a path helper the checks cannot reach.
 */
export const productName = "Voice Forge";

export function supportDir(): string {
  if (process.platform === "darwin") {
    return join(homedir(), "Library", "Application Support", productName);
  }
  if (process.platform === "win32") {
    // %APPDATA% is the roaming profile, where per-user application data belongs.
    const appData = process.env.APPDATA;
    return join(appData && appData.length ? appData : join(homedir(), "AppData", "Roaming"), productName);
  }
  // XDG: data goes in XDG_DATA_HOME, defaulting to ~/.local/share, and a
  // lowercase hyphenated name is the convention.
  const xdg = process.env.XDG_DATA_HOME;
  return join(xdg && xdg.length ? xdg : join(homedir(), ".local", "share"), "voice-forge");
}

export const voicesDir = () => join(supportDir(), "Voices");
export const sessionFile = () => join(supportDir(), "session.json");
export const pronunciationFile = () => join(supportDir(), "pronunciation.json");

/** Create the directories, ignoring failure — a missing folder shows up as "no
 * installed voices", which is the right thing to display anyway and better than
 * refusing to start. */
export function ensureDirs(): void {
  for (const d of [supportDir(), voicesDir()]) {
    try { mkdirSync(d, { recursive: true }); } catch { /* shown as empty */ }
  }
}
