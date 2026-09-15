# Expressive delivery: current evidence and next work

## 2026-09-15 baseline

The listener rejected the stronger DSP pass: it sounded worse and clipped.
The sample-peak checks had passed despite saturation and instantaneous
waveshaping. They did not establish listening quality. Those stages and the
unused resampling/pitch controls have now been removed from the expression code.

The remaining presets change Piper's sentence-wide scales and apply mild EQ.
Their emotional labels are provisional. No listening result yet demonstrates
convincing happiness, anger, flirtation, or intimacy from these treatments.

Direct inspection of the bundled ONNX model reports inputs `input`,
`input_lengths`, and `scales`, with `output` as the sole output. The current
adapter supplies three global scales; it exposes neither a style prompt nor
per-word durations or a pitch contour. Padding phonemes can influence duration,
but the voice decides their realization. A long beat is not an exact pause.

## Controlled listening

Run `npm run audition` in `cross-platform`. The command creates a unique
temporary directory with a listening page, WAV files, and a JSON manifest.

- EQ: one original Piper recording, copied through each EQ recipe. No change
  to inference, pitch, or timing. Loudness is matched by scalar gain only.
- Cadence: plain text, focus on “you”, focus on “stole”, and a beat before the
  reveal. Both noise scales are zero. The tool verifies a second baseline
  render is identical. These controls intentionally differ from ordinary
  stochastic synthesis.
- The manifest records source hashes, settings, duration, level adjustment,
  loudness, and sample peaks. Sample peaks do not certify intersample headroom
  or absence of audible distortion.

Evaluate intact words and naturalness first. Then judge whether the intended
word receives focus, the pause lands correctly, and tonal treatment helps.
Automated checks must not award “emotional” or “clean” quality based on duration
spread or EQ brightness. Linearity regression checks detect the old waveshaper
failure; listening remains necessary.

## Responsiveness

Take loudness is cached and measured off the main actor. Sentence re-rendering
now uses a detached task, with busy guards preventing overlapping synthesis
requests. Markup scanning checks a bounded cue only at an opening bracket;
it no longer lowercases the remaining script at every character. An empty
render clears selection and invalidates the measurement preview.

The app is packaged with the release configuration for ordinary use. Compile
and core checks do not constitute a measurement of mouse-to-highlight latency.

## Direct duration experiment — 2026-09-15

The user also rejected the remaining presets as indistinguishable on the Suno
and Rode voices. More PAD tokens or stronger EQ are not evidence of progress.

Inspection of the supplied epoch-702 Suno ONNX found the predicted duration
tensor immediately before frame rounding. A separate experimental copy now
accepts per-token duration factors, preserving the original trained tensors.
It does not require re-exporting an older checkpoint. All-one factors produced
sample-identical output on four sentence lengths. Targeted word-span factors
added 151 ms to “you” or 430 ms to “stole”; other token durations were unchanged.

See [the isolated experiment](../experiments/piper-timing/README.md) for source
provenance, reproduction, measurements, and limitations. It is not installed
in either app, and the Rode model is not yet tested. The stock adapter cannot
load this additional-input model without implementation work.

The user reports that restoring the configured acoustic noise scale (0.667
instead of the parity test's zero) removed glitchiness in the diagnostic clips.
Alignment and output length remained exactly unchanged. However, whole-span
2.5× stretching produced “ssttoollee”, not natural emphasis.

The vowel-only comparison keeps acoustic noise at 0.667 and adds 70 or 104 ms
around “stole”. All consonant and other unselected token durations are verified
unchanged. The user prefers the stronger variant for dramatic delivery and
proposes a pitch lift at “stole”, drop, and rise at “it”.

A separate pitch-only prototype now applies that relative contour to the exact
preferred WAV using the locally installed Rubber Band Live processor. No
new synthesis take, duration change, EQ, or app integration is involved. Delay
compensation and synthetic pitch/timing checks pass; listening approval is
pending. This is post-processing, not an explicit pitch input to Piper.
Validate word mapping and quality before app integration.
Believable emotional acting still requires separate evidence; timing control
alone does not demonstrate happiness, anger, flirtation, or intimacy.
