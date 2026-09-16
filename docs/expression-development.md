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

On 2026-09-16 the user found this contour clean but barely different. Analysis
of the actual speech found the second rise was scheduled after the final
voiced region; token alignment and sine calibration were insufficient to place
it. A hash-bound, manually placed test now targets the voiced region and uses
stronger pitch contrast. Paired AC/CC estimates confirm upward shifts in both
target regions, with the recording's duration preserved. The user rejects this
revision as riding an oscillating wave: “I didn't say you StOoOlEiT”. This is
not approved prosody, and this fixed-clip correction is not a general word
aligner. The measurements proved pitch movement, not natural intonation.

Keep the preferred vowel-timing result separate from these rejected pitch
curves. Do not integrate the contours or respond by making them still stronger.
A user-performed reference was requested so placement and phrase shape need
not be inferred from written arrows. The user has now supplied a 10.7-second
recording with three deliveries. The local analysis preserves each take as
original PCM, records source hashes, and measures relative pitch only where
two estimators agree. Estimated activity spans are 1.77, 1.52, and 2.14 seconds;
the third has the widest measured pitch range. The user selected Take 3.

A local recognizer identifies the same six words in both recordings. Its
approximate emission landmarks, combined with voiced pitch measurements,
indicate Take 3's high “you”, lower “stole”, and lifted “it”. A first audition
transfers these broad relative word registers while retaining the preferred
synthetic timing. It is not a full prosody transfer or forced word alignment.
The final word's measured shift has unresolved octave ambiguity, explicitly
recorded as unverified; listener approval is pending. No emotional label or
finished capability is claimed. All pitch changes remain experiment-only.

The user then supplied a cleaner, normalized R7 recording as the updated
reference. It contains one rendition, with different measured pitch relations:
lower “you”, higher “stole”, then higher “it”. New analysis and a separate
word-register audition use R7's actual landmarks instead of old Take 3's
pattern. Synthetic pacing is retained; no full performance match is claimed.
Output pitch ambiguity persists on two words and is explicitly unverified.
The user rejected this R7 audition as losing voice coherence/body and becoming
weak/airy. The app remains untouched. An exact replay isolates the pitch-changing
path: the neutral Rubber Band pass is near-identical, while disabling formant
preservation restores some measured level but is not an established timbre fix.
Improved periodicity measurements in the rejected clip do not override listening.

A separate Praat TD-PSOLA benchmark now uses the same accepted source, R7 curve
and duration, with a genuinely resynthesized zero-shift control. Neutral word
levels and estimated pitch stay close to the source. The shifted output still
fails verification: too few reliable frames on “you” and an unresolved octave
disagreement on “it”. Both retain the recognized sentence; that does not certify
coherence. The shifted output is not promoted as a replacement audition. The user
now reports that the original and zero-shift control sound identical by ear:
that specific control passes, without implying approval of pitch changes.

The next isolated check copies only the existing shifted “stole” region into the
preferred source. “You”, “it”, and the rest outside the approximate 1.2–1.6s
window remain sample-identical; duration is unchanged. The +4.42-semitone measured
shift is consistent with the existing command, but the user rejects the result
as stretched “stoole” with light high/low crackling or static embedded in it.
No stronger curve, new inference, gain compensation or app integration was added.
A localized neutral control is retained to distinguish splice artifacts.

Integrity checks confirm no added samples or sample clipping; the middle 370ms
is exactly the existing TD-PSOLA output, untouched by the new edge crossfades.
These checks narrow the diagnosis but do not identify the crackling mechanism.
The source's +104.49ms vowel extension was inherited from the earlier timing
test; unchanged duration does not negate perceived stretching. Stop promoting
this shifted version, preserve the neutral listening pass as control-only, and
require a causal resynthesis test before another expressive audition. No new
clip or app change accompanies this rejection.

The next approved step is a bounded original-duration pitch diagnostic. It reuses
a saved Suno baseline with normal acoustic noise and no vowel extension. A
waveform/pulse audit finds floor-sensitive tracking at the onset of “stole”, but
more consistent tracking in its middle. No analysis setting is declared corrected.
Constant +1 and +4.45-semitone offsets measure approximately +0.94 and +4.38 in
that stable core. All versions retain source duration and unchanged samples
outside the approximate word region; there is no expressive curve or gain fix.

A dry / neutral / small-shift / larger-shift listening sequence is available in
the experiment's `original-duration-fixed-pitch-verified` directory. Listening
approval is pending for this new source and all its controls. A no-op in the
first constant-shift implementation was caught and corrected before audition;
known-tone and output-identity regressions now cover it. The alternative 40Hz
analysis is retained as a sensitivity test, not promoted based on measurements.
WORLD, the Rode voice, additional sentences and app integration remain deferred
until this controlled listening check establishes whether fixed pitch movement
preserves the voice. The pulse plot guided selection of the measurement region,
not a claim that the complete audible word is artifact-free.

The user localizes slight crackling to “t” in the +1 and +4.45 versions of that
sequence. A new onset-guard test preserves the dry source through 1.390s, then
crossfades to the existing shifted output by 1.410s. This protects both the
consonant and the disputed vowel onset; later shifted audio stays sample-identical
to the prior variants. The shift magnitude is retained, but its onset is delayed.
This is a manual fixed-clip ablation, not a general consonant detector or proven
fix. The new neutral control and both guarded shifts await listening for removal
of the “t” crackle without merely moving an artifact into the vowel. Seven
diagnostic tests pass; app integration and alternative-renderer work remain deferred.
See the experiment README and its diagnostic manifests for reproducible evidence.
Believable emotional acting still requires separate evidence; timing control
alone does not demonstrate happiness, anger, flirtation, or intimacy.
