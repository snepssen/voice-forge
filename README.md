# Voice Forge

**[The page →](https://snepssen.github.io/voice-forge/)**  ·  screenshots, the measurements, and the downloads.

A text-to-speech tool with the synthesiser's dials on the outside, built on a
Piper/VITS voice fine-tuned from about forty minutes of my own speech.

Most text-to-speech hides the machine and gives you a speed slider. That is the
wrong dial. A synthesised read sounds wrong not because the timbre is off but
because every beat lands at the same metronomic distance — and speech lives in
the uneven ones. So this puts the timing on the outside, measures what each
control actually buys **per voice**, and prints the number next to the dial.

    a comma on the bundled voice          145 ms
    a comma on a voice not shipped here   457 ms

Same speaker, three times apart. The second voice was trained for the meditation
app this engine came from and stayed with it — but the gap is the point: a
measurement taken from one voice does not describe another, so *Measure this
voice* is a button rather than a printed constant, and the app will not print one
voice's figure under another's name.

The text decides the delivery, and there is no switch for it. A sentence is read
rather than recited: the point of each phrase is held a little and lifted, a
phrase settles at its clause mark, unstressed words give way, and a word already
said in the paragraph steps back the second time. That happens per *sound* — a
vowel can be held, a stop cannot, and holding one anyway is what turns a
stretched word into a stutter.

It is the timing the model is told, not a filter over what it produced. The
bundled voice's graph carries an extra input for per-token duration, and feeding
it a vector of ones reproduces the stock model bit for bit, which is how the
change was shown to be inert before any of it was switched on. A voice installed
from elsewhere has no such input and renders exactly as it always did.

Inside a sentence, `*focused words*` receive their own stress and room, while
`[[beat:short]]`, `[[beat]]` and `[[beat:long]]` add authored breaths to the same
model call. Pronunciations can be edited as IPA or seeded from an ordinary
“sounds like” respelling and inspected before use.

There is no emotion selector. One was built — Happy, Playful, Intimate, Flirty,
Angry — and it is gone from the interface because it did not earn its place. The
honest reason is in [docs/expression-development.md](docs/expression-development.md):
this voice is not style-conditioned, so an expression could only reach pace, two
noise scales and some EQ, and none of the three survived. The pace moved 2% of a 13% request
because the graph rounds every token up to a whole frame. The noise scales only
redrew the dice. The EQ read as loudness rather than character. Rebuilding it on
the timing layer made the six measurably different — and still not convincing
enough to keep a control for.

For controlled listening comparisons, run `npm run audition` from `cross-platform`.
It creates a local HTML page with playable WAVs and a JSON measurement manifest.
EQ comparisons reuse the exact same recording, with loudness matched using gain
only. Separate phrase-direction comparisons disable both Piper noise scales and
verify a repeatable baseline. These are experiments for listening evaluation;
passing signal checks does not establish naturalness or emotional expression.

## Two implementations

| | | |
|---|---|---|
| [`macos/`](macos) | Swift, SwiftUI, ONNX Runtime | native Mac app |
| [`cross-platform/`](cross-platform) | TypeScript, Electron, ONNX Runtime | Windows and Linux |

The interface is drawn in HTML on the cross-platform side rather than handed to
GTK or Qt, so it looks the same everywhere instead of being three apps that
happen to share a name.

**The two cores are held to each other.** 20 parity checks compare phonemes
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

## The wider workshop

- [Gateway Forge](https://snepssen.github.io/gateway-forge/) — guided-session
  authoring using the same measured speech engine.
- [Voice Forge](https://snepssen.github.io/voice-forge/) — this project.
- [Protoke](https://snepssen.github.io/protoke/) — lyric and narration video
  with a word-timed vector face.
- [tools-core](https://snepssen.github.io/tools-core/) — corpus, audio, and
  speech-research utilities.

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
