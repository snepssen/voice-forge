# The bundled voice is a patched graph

`extend_onnx.py` is the tool that made it, and it is here because the voice this
app ships is not a stock Piper export. Anyone asking how that `.onnx` was
produced should be able to find the answer beside it.

## What the patch does

A stock Piper graph predicts a duration for every phoneme token, multiplies the
lot by one global length scale, and rounds up to whole frames. There is no way
to ask it for a different length on one sound, which is the control this app
needs: holding a vowel reads as delivery, and holding the stop next to it reads
as a defect.

The tool inserts an elementwise multiply immediately before that rounding and
exposes it as a fourth input, `vf_duration_factors`, float32 `[batch, 1,
phonemes]`. It also exposes the duration tensors either side of the change, so a
caller can verify what its factors actually bought rather than assuming.

**No weights are touched.** It reads the source, writes a separate destination
with an exclusive open, and refuses any graph that does not match the single
inspected pattern rather than guessing which tensor carries timing.

## The property the whole thing rests on

A factor of one must reproduce the unpatched model exactly. That was checked at
four sentence lengths in the experiment, and again through the app's own render
path when the patched voice was installed: identical sample counts and identical
SHA-256 over the output, on four sentences. Not within a tolerance — the same
bytes.

It matters because every measurement this app prints was taken against the
unpatched engine. If a vector of ones drifted, those figures would quietly stop
describing the thing they are printed next to.

## Rebuilding it

Needs an isolated Python environment with `onnx` (built with 1.22.0). The source
model needs its `.onnx.json` sidecar beside it.

```sh
python experiments/piper-timing/extend_onnx.py /path/to/stock.onnx /path/to/patched.onnx
```

`macos/build.sh` will refuse to package a voice that cannot be told its own
timing, and names this script in the error, so a stale or unpatched model cannot
ship silently.

## The rest of the experiment is not here

Getting to this point took a long run of measurements, and most of them were
failures worth keeping: five separate attempts at moving pitch after synthesis —
Rubber Band contours, register transfer from performed references, TD-PSOLA
resynthesis, single-word isolation, constant-offset shifts — every one rejected
by ear. Their scripts, their audio, their reports and the listening verdicts are
on an external archive with a README of their own.

Two conclusions from that work are load-bearing here, so they are written down
rather than left on the drive:

- **Post-synthesis pitch does not work on this voice.** The one variant that
  ever passed a listening check depended on a hand-placed boundary in one clip.
  That is why nothing in the app shifts pitch, and why reaching for it again
  should start from evidence rather than from another contour.
- **The graph rounds each token's duration up to a whole frame**, and the median
  token on the bundled voice is two frames. A direction under about 20% moves
  nothing at all — a 5% one moved 1 token in 123. Anything built on this control
  has to work in large moves on few sounds.

Where intonation *is* reachable is in the stress marks, which the model was
trained on and answers to natively: `core/phonology.ts` and its Swift twin carry
that as `restress`, with the measured pitch ranges in the comment.
