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

## Contact

`CONTACT` in `src/main/index.ts` holds a Telegram link and an email address, and
both are **placeholders** until somebody sets them. The Help sheet says so
rather than opening a dead link.

There is no updater and no crash reporter, which is deliberate — and it means a
failure has no way of reaching anybody on its own. The Help sheet is the whole
support surface: version, platform, Electron and Node versions, which voices are
present. It puts them on the clipboard for the person to read before sending.
The script and the dictionary are **not** included; a diagnostic that quietly
carries somebody's unreleased voiceover into a support chat is worse than none.

## Verified on

- **macOS 15, Apple Silicon** — development, all suites, packaged app.
- **SteamOS 3, Steam Deck (x86_64)** — the packaged `tar.gz`, 2026-09-01.
  Launches, renders, plays, exports, and sounds right, which is the check that
  matters most: it means the espeak-ng data travelled and the phonemizer did not
  fall back to its own.
- **Windows** — not yet. Needs a machine or the CI workflow.

## Building artifacts

```bash
npm run dist:win      # NSIS installer + zip
npm run dist:linux    # tar.gz, AppImage, deb
```

**Each platform builds its own, and that is not laziness.** Cross-building from
a Mac gets partway and stops: the Linux app tree builds correctly — a real
aarch64 ELF with every resource in place — but electron-builder ships an
**x86_64** `mksquashfs` for macOS hosts, so AppImage cannot be produced on Apple
Silicon at all (`bad CPU type in executable`), and NSIS needs wine. `tar.gz` is
the one Linux target that builds anywhere, and it is complete: app.asar, the
voice, all 952 espeak-ng data files and the training guide.

`.github/workflows/build.yml` runs each platform on itself, gated on all three
check suites. It publishes nothing and sets up no update channel.

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
