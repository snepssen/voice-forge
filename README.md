# Voice Forge — Windows and Linux

The Mac build stays Swift, in `../voice-forge`. This is the same app for
everywhere else: Electron and TypeScript, drawing its own pixels so it looks the
same on all three platforms rather than borrowing whatever GTK or Qt would
render.

```bash
npm install
npm run check     # the core suite — never loads a model
npm run parity    # against the Swift build's own numbers
npm run smoke     # a real script, end to end, no window
npm start
```

## What has to stay true

**The espeak data in `resources/espeak-ng-data` is this app's, not the npm
package's.** `piper-phonemize` bundles a newer espeak-ng whose en-us rules moved
the NORTH/FORCE vowel from `ɔːɹ` to `oːɹ`. Measured across 35 ordinary words,
8 differed and every difference was that one — *four, before, more, door,
important, course, report, support*. The model was trained on `ɔːɹ`.

`initialize()` fails **open**: point it at the wrong place and the package
quietly uses its own data. Nothing errors, the app still speaks, and it is
wrong in some of the commonest words in English. `npm run parity` owns those
eight words for exactly that reason.

**`npm run check` must never load a model.** Same rule as `vfcheck` on the Swift
side, same reason: this project's subject is what the engine does, so the thing
measuring it has to be the cheap part.

**Nothing here talks to the network.** Chromium's background chatter is switched
off explicitly in `refuseToPhoneHome()` rather than assumed absent, the page runs
under a `default-src 'none'` CSP, and navigation is refused outright. There is
no updater and no crash reporter.

## If `npm install` leaves Electron broken

npm may block the package's postinstall, which is what downloads the ~95 MB
binary. The symptom is `Electron failed to install correctly`. Run its installer
by hand:

```bash
node node_modules/electron/install.js
```

If that leaves `node_modules/electron/dist` at a few hundred KB the download
timed out partway — fetch the release zip for your platform, unzip it into
`node_modules/electron/dist`, and write the relative path to the binary into
`node_modules/electron/path.txt` with **no trailing newline**.
