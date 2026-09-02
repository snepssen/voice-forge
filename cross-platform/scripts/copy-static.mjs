// The page's HTML and CSS are not TypeScript, so tsc will not carry them to
// `out/`. They belong beside the compiled renderer, where its `../core/*.js`
// imports resolve.
import { copyFileSync, mkdirSync } from "fs";
mkdirSync("out/renderer", { recursive: true });
for (const f of ["index.html", "style.css"]) {
  copyFileSync(`src/renderer/${f}`, `out/renderer/${f}`);
}
console.log("copied the page into out/renderer");
