# Training your own voice

Voice Forge ships one voice and will use any other you give it. A voice is two
files — a Piper model and its config — and this is how to make a pair.

**Work through this with an LLM open beside you.** Not as a shortcut: the
process has a dozen small decisions that depend on your machine, your recording
and your patience, and a model that can read your actual error messages and your
actual audio durations will get you unstuck faster than any fixed instruction
can. Paste this file in, tell it what hardware you have, and let it adapt. The
places where that matters most are marked **ask about this**.

Everything below was measured while training the voice this app ships with, on
a 16 GB M1 MacBook. Numbers from other people's guides are often from a rented
A100 and will mislead you badly about time and memory.

---

## What you need

- **30–60 minutes of your own clean speech.** More is not obviously better; the
  shipped voice used about 42 minutes. Consistency beats quantity — one
  microphone, one room, one distance, one session if you can manage it.
- **A transcript**, exact to the word.
- **A machine with a GPU**, or a lot of patience. Apple Silicon works through
  MPS. **Ask about this** — it is the decision that sets everything else.
- **Piper's training fork**: `github.com/OHF-Voice/piper1-gpl`.

## 1. Record

Read prepared text rather than improvising. Improvised speech is full of
restarts and "um", and every one of those teaches the model to do it.

Record in one take if you can, and edit after. A single take gives you one noise
floor, one level and one mood, which is worth more than a perfect line read.

Leave the room quiet. Do not noise-gate during recording — gating carves holes
at exactly the low-energy moments the model needs in order to learn how your
voice trails off, and a model trained on gated audio ends sentences on a cliff.

## 2. Cut it into clips

This is the step that decides whether your voice sounds right, and it is the one
most guides skip in a sentence.

You need clips of a few seconds each, paired with their exact text. The rules
that matter:

- **Cut at silence, never mid-word.** A clip that starts halfway through a
  consonant teaches the model that words begin that way. The voice this app
  ships with had a stutter — a "y-you" at the start of lines — that came from
  exactly this, and no amount of further training fixed it. Re-cutting the
  corpus did.
- **Do not trim tight.** Leave 100–150 ms before the first sound and up to
  700 ms after the last. A corpus trimmed hard at the end teaches the model that
  utterances stop abruptly, and it will reproduce whatever sat at your cut —
  a breath, a click, the beginning of the next word. Voice Forge's *trailing
  padding* and *drop the final full stop* settings exist to paper over exactly
  this, and you would rather not need them.
- **Take the text from your script, never from a transcriber.** Use ASR to find
  *where* each line falls in time, then pair that timing with the script's own
  words. Transcribers silently normalise: they will write "you" where you said
  "y-you", and the model then learns to attach that stumble to the wrong sound.
- **Check clip lengths, not just word error rate.** A clip whose audio is much
  longer or shorter than its text is the signal that something slipped. WER will
  not show it.

**Ask about this** — describe your recording and your editor and get a
segmentation script written for your actual files.

## 3. Train

Fine-tune from a pretrained checkpoint. Do not train from scratch; you do not
have enough audio, and warm-starting from an existing English voice gives you
the language for free and lets your recording supply only the identity.

**Batch size is a cliff, not a dial.** Measured on a 16 GB machine, with a
corpus whose median clip was 6.3 s:

| batch size | speed |
|---|---|
| 8 | 0.01 it/s |
| 4 | 0.17 it/s |

Seventeen times, for one power of two. It is not compute — the CPU sat at 14%
while free memory sat at 14%. Piper's loader does not bucket by length, so every
batch pads to its longest clip, and one size too large tips the machine into
swapping. **A wrong batch size does not fail. It quietly takes a month.**

So: run one partial epoch, measure it/s, and only then commit days to it. Free
memory percentage plus an idle CPU is the signature. **Ask about this** with
your numbers.

Expect to leave it running for days, and to check in rather than watch.

## 4. Export

Piper exports to ONNX. You want the two files it produces together:

```
en_US-yourname-medium.onnx
en_US-yourname-medium.onnx.json
```

The `.json` is not optional — it carries the phoneme table, the sample rate and
the inference defaults, and the model is unusable without it. Voice Forge will
refuse a model whose config is missing and tell you so.

Verify the export before trusting it: trace at one text length and run at
another. Export bugs in this pipeline have a habit of freezing a length into the
graph, which produces a model that works perfectly on the sentence you tested
and garbles everything else.

## 5. Install it

Put both files in:

- **macOS** — `~/Library/Application Support/Voice Forge/Voices/`
- **Windows** — `%APPDATA%\Voice Forge\Voices\`
- **Linux** — `~/.local/share/voice-forge/Voices/`

Restart Voice Forge. The voice appears in the picker by the middle part of its
filename, so `en_US-yourname-medium.onnx` shows up as **yourname**. A voice you
install with the same name as the bundled one replaces it.

Then **measure it**. Press *Measure this voice* — the pause numbers are per
voice and do not transfer. The two voices trained for this project differ by
31% in reading speed and by a factor of three at a comma, from the same speaker.
Your voice's numbers are yours.

---

## What to expect

It will not sound like you on the first try, and the gap usually is not the
model. In order of how often it is the cause: the corpus segmentation, the
recording consistency, the batch size, and only then the training itself.

The voice will also be *even* in a way you are not. Its articulation rate can be
within a fraction of a percent of yours while still sounding mechanical, because
what it flattens is the long pauses — rare events, which a duration predictor
regresses toward the mean. That is what Voice Forge's pause controls are for,
and it is why they exist as separate dials rather than a single "speed".
