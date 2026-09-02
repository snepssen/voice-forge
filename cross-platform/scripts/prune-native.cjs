/**
 * Drop the native binaries that are not for the platform being packaged.
 *
 * `onnxruntime-node` ships every platform it supports — darwin, linux and
 * win32, each in x64 and arm64 — which is right for a package and wrong for an
 * app. Measured on the Linux x64 build: 152 MB of ONNX binaries shipped, of
 * which 43 MB was the one that could ever run. The other 109 MB was Windows
 * DLLs and macOS dylibs riding along inside a Linux archive.
 *
 * electron-builder's `files` globs cannot express "the current arch", so this
 * runs afterPack where the target is actually known.
 */
const { rm, readdir } = require("fs/promises");
const { join } = require("path");
const { existsSync } = require("fs");

const ARCH = { 0: "ia32", 1: "x64", 2: "armv7l", 3: "arm64", 4: "universal" };

exports.default = async function pruneNative(context) {
  const platform = context.electronPlatformName;              // darwin | linux | win32
  const arch = ARCH[context.arch] ?? "x64";
  const root = context.appOutDir;

  // Where the unpacked node_modules land differs by platform.
  const candidates = [
    join(root, "resources", "app.asar.unpacked", "node_modules", "onnxruntime-node", "bin"),
    join(root, "Voice Forge.app", "Contents", "Resources", "app.asar.unpacked",
         "node_modules", "onnxruntime-node", "bin"),
  ];
  const bin = candidates.find(existsSync);
  if (!bin) return;

  let removed = 0;
  for (const napi of await readdir(bin)) {
    const napiDir = join(bin, napi);
    for (const p of await readdir(napiDir)) {
      const platDir = join(napiDir, p);
      if (p !== platform) { await rm(platDir, { recursive: true, force: true }); removed++; continue; }
      for (const a of await readdir(platDir)) {
        if (a !== arch) { await rm(join(platDir, a), { recursive: true, force: true }); removed++; }
      }
    }
  }
  console.log(`  • pruned ${removed} native directory(ies) not for ${platform}/${arch}`);
};
