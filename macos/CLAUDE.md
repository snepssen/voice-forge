# Voice Forge — working context

A standalone macOS text-to-speech app built on the Piper/VITS engine written for
Gateway Forge. One voice ships — `snepssen`, fine-tuned on the owner's own
speech — and any Piper voice can be installed beside it. Local, single
executable, no network, no Python.

**Voice Forge is the other half of Gateway Forge's engine.** That app settles
the synthesiser's numbers and never shows them, which is right for a meditation
tape: one voice that does not drift under a listener. This one is for voiceover,
where shaping it is the entire point — so the same three scales, the same
padding decisions and the same pause behaviour are on the outside, with what
each is worth printed underneath.

The engine was **copied, not shared**. The two apps want different things from
the same model and a shared target would have to serve both; divergence should
be a deliberate edit visible in this project's own history. One difference
exists already: Gateway Forge respells `I-There` and `REBAL` before espeak sees
them, because those are its own vocabulary. A general TTS tool must not quietly
rewrite the words it was given, so that table is gone.

### Voices

One voice is bundled and **it is not privileged**: `VoiceEngine.availableVoices()`
merges the bundle with whatever is in the user's voices folder, and an installed
voice of the same name wins — so somebody who retrains `snepssen` gets theirs
without having to rename it to escape ours. A voice is a Piper `.onnx` plus its
`.onnx.json`; the name is the middle field of the filename, and parsing stays
permissive because `en_GB-alice-high` is a perfectly good voice this app has no
stake in rejecting. A model with no config is refused *by name* — somebody who
just spent days training should be told which file is missing, not find their
voice quietly absent from a menu. `TRAINING.md` is the guide, and ships inside
the app so it works with no network.

`snepssen-rode` is no longer bundled. It lives on in Gateway Forge, where it was
measured, and can be installed here like any other voice.

### Appearance

Light and dark, toggled in the toolbar and persisted. Every colour is one
`NSColor` dynamic value, so the ~200 existing `Monokai.x` call sites did not
change — threading a palette through the environment would have been a large
diff to reproduce what AppKit already does. This is the one deliberately
Apple-only mechanism in the app; a port carries the hex values across, not this.
The light side is not an inversion: Monokai's character is its hues against a
warm ground, so the ground stays warm and the hues darken until they carry on
paper.

```bash
./build.sh                       # checks -> build -> Voice Forge.app
swift run vfcheck                # checks only (77 passing)
swift run vfrender voices        # what is bundled
swift run vfrender say <voice> "text" out.wav
swift run vfrender calibrate <voice>
swift run vfrender probe <voice> ["text"]   # amplitude envelope, for diagnosis
```

`vfcheck` **must never link VoiceForgeTTS.** Same rule as `gfcheck`, and it
matters more here: this project's subject is what the engine does, so the thing
that measures it has to be the cheap part.

---

## What will bite you

**One inference call per sentence. Never less, never more.** Flattening several
sentences into one call is off-distribution — Piper phonemizes a sentence at a
time and so did the fine-tuning — and was heard as a phantom "-eth" on the last
sentence in eight draws of eight. Cutting *inside* a sentence is the opposite
error and costs a stutter at the seam, because each call starts cold with no
audio context; that was heard as "y-you". Everything this app offers by way of
pause control is built either between sentences, where a real boundary exists,
or inside one call by giving the model more room — never by cutting a sentence.

**The model is stochastic.** `noise_scale` varies the sound and `noise_w` varies
the durations, so the same sentence rendered twice differs. Any measurement of a
duration must either force `noiseW` to zero or average many draws. The first
version of the pause calibration did neither and produced pure noise: successive
draws at 0, 4, 8 and 12 clause pads gave longest-gap figures of 434, 213, 300
and 265 ms, no trend at all, while the totals went 3.29, 3.27, 3.48, 3.69 s.

**The model has no silence, only quiet.** Its pauses sit around 0.005–0.01
amplitude — breath, not digital zero. A threshold of 0.002 reported an 11 ms
comma on a line where 0.01 reported 434 ms. Any answer from a fixed threshold is
an artifact of the threshold. Measure pauses by **difference in total duration**
between the same words with and without the mark: nothing has to be located, and
the words either side are identical by construction.

**Measured on `snepssen-rode` at pace 1.0**: a comma is worth about **457 ms**
(range 197–952 across the probe set), `;` and `—` about 542, `:` about 557, and
one clause pad buys about **35 ms**. The ranges are wide because the duration
predictor is conditioned on context — the app prints the range, not one
confident number.

**Loudness is real BS.1770-4**, not an approximation, because an approximate
LUFS would be believed. The K-weighting filters are derived from the analog
prototype by bilinear transform at the rate passed in, never copied from the
published 48 kHz table — the model speaks at 22.05 kHz. A 1 kHz tone at -20 dBFS
**RMS** reads -19.99 LUFS at 48 kHz and -19.96 at 22.05 kHz. (A 0.1-*amplitude*
sine is -23 dBFS RMS; getting that backwards is the classic way to "find" a 3 dB
bug in a correct implementation.)

**A single voice usually cannot reach -14 LUFS on gain alone.** Speech with hard
consonants and real silences has a high peak-to-loudness ratio, so the true-peak
ceiling stops the gain first. The app holds the gain at the ceiling and says so
rather than clipping quietly. Closing that gap needs compression, which this app
deliberately does not do.

**The packaging gate names no voice.** It derives the expected set from
`Sources/VoiceForgeTTS/Resources`, prunes anything the app carries that source no
longer declares, and requires the two sets to match in both directions. Gateway
Forge's gate named a file, that file was deleted from source, SwiftPM kept a
staged copy in `.build`, and the app shipped a third voice nobody had trained —
offered in the picker like any other, because the engine enumerates by name.

**Trailing padding of 2 and dropping the final full stop are measured optima**,
carried over with their measurements (see `SynthesisSettings`). Padding is not
monotonic: three is worse than two, because too much room lets the model start
voicing into it.
