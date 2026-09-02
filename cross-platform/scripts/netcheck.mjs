/**
 * Proves the app makes no network connections, rather than asserting it.
 *
 * Every name the app could resolve is mapped to a local listener, so any
 * attempt to reach anything — Chromium's field-trial fetch, an updater, a
 * crash upload, a font, anything at all — arrives here and is recorded. The
 * app is then launched, given time to boot the window and load a voice, and
 * killed. An empty log is the pass.
 *
 * `--host-resolver-rules MAP * 127.0.0.1:port` is the right instrument because
 * it catches connections the app never told us about. A `webRequest` hook only
 * sees what the renderer asks for, which is precisely the half that was never
 * in doubt.
 */
import { createServer } from "net";
import { spawn } from "child_process";
import { readFileSync } from "fs";
import { join } from "path";

const hits = [];
const server = createServer(socket => {
  hits.push({ at: new Date().toISOString(), from: socket.remotePort });
  socket.destroy();
});

await new Promise(r => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
console.log(`listening on 127.0.0.1:${port} — every hostname is mapped here`);

const electron = join("node_modules", "electron", "dist",
  readFileSync(join("node_modules", "electron", "path.txt"), "utf8").trim());

const child = spawn(electron, [
  ".",
  `--host-resolver-rules=MAP * 127.0.0.1:${port}`,
  "--proxy-server=127.0.0.1:" + port,
], { stdio: ["ignore", "pipe", "pipe"] });

let stderr = "";
child.stderr.on("data", d => { stderr += d.toString(); });

const seconds = Number(process.env.NETCHECK_SECONDS ?? 20);
console.log(`running the app for ${seconds}s…`);
await new Promise(r => setTimeout(r, seconds * 1000));
child.kill("SIGTERM");
await new Promise(r => setTimeout(r, 1500));
server.close();

for (const l of stderr.split("\n").filter(l => l.includes("[page]"))) console.log(l);

// Two stacks, two ways of catching them. The resolver rules cover Chromium;
// `netguard` covers Node, and reports what it refused. A check built on only
// the first passed with a `fetch()` planted in the main process.
const blocked = stderr.split("\n").filter(l => l.includes("[netguard]"));
for (const l of blocked) console.log(l.trim());

if (hits.length === 0 && blocked.length === 0) {
  console.log(`\nno outbound connections in ${seconds}s — the app did not reach for anything`);
  process.exit(0);
}
console.log(`\n${hits.length + blocked.length} outbound attempt(s): `
  + `${hits.length} reached the listener, ${blocked.length} refused by netguard`);
for (const h of hits.slice(0, 10)) console.log(`  chromium: ${h.at}`);
process.exit(1);
