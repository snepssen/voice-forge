# Voice Forge

A text-to-speech tool with the synthesiser's dials on the outside, built on a
Piper/VITS voice fine-tuned from about forty minutes of my own speech.

Most text-to-speech hides the machine and gives you a speed slider. That is the
wrong dial. A synthesised read sounds wrong not because the timbre is off but
because every beat lands at the same metronomic distance — and speech lives in
the uneven ones. So this puts the timing on the outside, measures what each
control actually buys **per voice**, and prints the number next to the dial.

    a comma on the bundled voice      145 ms
    a comma on the other voice        457 ms

Same speaker, three times apart. A measurement from one voice does not describe
the other, and the app refuses to print one under the name of the other.

## Two implementations

| | | |
|---|---|---|
| [`macos/`](macos) | Swift, SwiftUI, ONNX Runtime | native Mac app |
| [`cross-platform/`](cross-platform) | TypeScript, Electron, ONNX Runtime | Windows and Linux |

The interface is drawn in HTML on the cross-platform side rather than handed to
GTK or Qt, so it looks the same everywhere instead of being three apps that
happen to share a name.

**The two cores are held to each other.** 18 parity checks compare phonemes
byte-for-byte and durations to the millisecond — 1.637 s against 1.637 s — with
the duration predictor made deterministic so the comparison means something. If
they ever disagree, one of the two suites goes red.

## Installing

    # macOS and Linux
    curl -fsSL https://raw.githubusercontent.com/snepssen/voice-forge/main/install.sh | sh

    # Windows, in PowerShell
    irm https://raw.githubusercontent.com/snepssen/voice-forge/main/install.ps1 | iex

Read them first if you like — they are short, and piping a remote script into a
shell is exactly the thing worth being suspicious of:

    curl -fsSL https://raw.githubusercontent.com/snepssen/voice-forge/main/install.sh | less

Each asks GitHub for the latest release, downloads the single archive for that
machine, **checks its SHA256 against the checksums published in the same
release**, and unpacks it. No sudo. Nothing written outside the paths it prints.

Or take a build from [Releases](https://github.com/snepssen/voice-forge/releases)
by hand.

**Two things worth knowing before you run it.** On macOS the app is signed
ad-hoc rather than notarised, so Gatekeeper would refuse it — the installer
clears the download quarantine flag, which is what you would do by right-clicking
Open, and says that it did. On Windows the installer is unsigned and SmartScreen
will warn you. Code signing costs money this project does not spend.

## Building

```bash
cd macos          && ./build.sh        # checks, then Voice Forge.app
cd cross-platform && npm ci && npm run check && npm start
```

`npm run check` never loads a model, which is what keeps it the cheap gate.
`npm run parity` and `npm run smoke` do. `npm run netcheck` proves the app makes
no network connections, and it is itself proved: a planted request has to make
it fail before a passing result means anything.

## Training your own voice

One voice ships and it is not privileged — drop a Piper `.onnx` and its
`.onnx.json` in the voices folder and it appears in the picker; install one
named the same as the bundled voice and yours wins. [`TRAINING.md`](TRAINING.md)
is the guide, and carries this project's own measurements rather than generic
advice.

## Licence

**GPL-3.0-or-later.** Not a preference: the app bundles espeak-ng and
piper-phonemize, both GPL-3.0-or-later, so anything distributed with them has to
be compatible.

## The page

[`docs/`](docs) is the project page — one HTML file, four screenshots, no build
step. Turn on GitHub Pages with the source set to **main / docs** and it is
live at `https://<username>.github.io/voice-forge/`.

The three download links point at `releases/latest/download/...`, which always
resolves to the newest release, so the page never needs editing when a version
ships.

## Contact

There is no updater and no crash reporter, which is deliberate — and it means a
failure has no way of reaching me on its own. [@snepssen](https://t.me/snepssen)
on Telegram, or <snepssen@proton.me>.
