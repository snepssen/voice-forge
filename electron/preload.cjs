// The whole bridge between the window and the app. Deliberately small: the
// renderer gets a fixed list of named requests and no access to Node, so a
// script that somehow ended up in the page cannot reach the filesystem.
const { contextBridge, ipcRenderer } = require("electron");

const invoke = (channel, ...args) => ipcRenderer.invoke(channel, ...args);

contextBridge.exposeInMainWorld("vf", {
  loadState:        ()            => invoke("state:load"),
  saveState:        (s)           => invoke("state:save", s),
  listVoices:       ()            => invoke("voices:list"),
  installVoice:     ()            => invoke("voices:install"),
  removeVoice:      (name)        => invoke("voices:remove", name),
  openVoicesFolder: ()            => invoke("voices:folder"),
  openTraining:     ()            => invoke("app:training"),
  vocabulary:       (voice)       => invoke("voice:vocabulary", voice),
  defaultPhonemes:  (voice, word) => invoke("voice:defaultPhonemes", voice, word),
  render:           (req)         => invoke("render", req),
  renderOne:        (req)         => invoke("render:one", req),
  applyReport:      (req)         => invoke("dictionary:report", req),
  calibrate:        (req)         => invoke("calibrate", req),
  exportTake:       (req)         => invoke("export", req),
  diagnostics:      ()            => invoke("app:diagnostics"),
  contact:          (kind)        => invoke("app:contact", kind),
  onProgress:       (fn)          => ipcRenderer.on("progress", (_e, p) => fn(p)),
});
