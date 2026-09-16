# Piper timing proof of concept

Isolated experiment, not an application feature. No retraining, EQ, pitch
resampling, saturation, or app model replacement.

## Inspected source

- User's Suno voice export: `/Volumes/Archive/voice-training-data/from-deck/gatewayforge-voice/voice-epoch702/en_US-snepssen-medium.onnx`.
- SHA-256: `710b6f9cf11d2e9c7fe786e534dc142c031009c62572f2d4a81117c34f335946`.
- This matches the currently bundled Suno ONNX. The archive folder name does
  not make this work part of the older Gateway Forge project.
- Available Mac checkpoints in `/Volumes/Archive/piper-data/runs/snepssen`
  end at epoch 564. The archive README identifies epoch 702 as a Deck export;
  we have not established a matching checkpoint among the supplied files.
- The Rode voice has not been tested by this experiment.

## What changes

The inspected graph predicts durations, multiplies by global length scale,
then rounds up (`Ceil`) to build its frame count and alignment path. The
patch inserts an elementwise multiplier immediately before that rounding:
`vf_duration_factors`, float32 `[batch, 1, phonemes]`.

It also exposes the original and modified rounded duration tensors for
verification. Original trained tensors are not edited. The tool rejects an
unrecognized graph pattern and exclusively creates a new output file.
This experimental model has an extra required input: **do not install it in
the stock app**, whose adapter does not supply that input.

Factors of one must preserve the waveform. This is a token-duration control,
not an emotion embedding, pitch control, or general word aligner. A fixed
English fixture uses verified phoneme word groups. Its selected span includes
intervening blank tokens, which have nonzero predicted frame counts. Those
frames are model alignment, not independently measured acoustic boundaries;
unchanged neighboring durations do not imply bit-identical neighboring audio.

## Reproduce

Use an isolated Python environment with `onnx` (tested with 1.22.0). Use the
cross-platform project's existing Node dependencies, and build its helpers:

```sh
npm --prefix cross-platform run build
python experiments/piper-timing/extend_onnx.py /absolute/original.onnx /absolute/new-timing.onnx
node experiments/piper-timing/audition.mjs /absolute/original.onnx /absolute/new-timing.onnx /absolute/new-listening-directory
```

The original model requires its `.onnx.json` sidecar. The audition uses the
bundled voice's phonemizer, verifies token encoding against the app, and is
only validated for the inspected English Suno model. Output WAVs and manifest
use exclusive creation; use a fresh output directory when repeating a run.

## Results on 2026-09-15

Baseline parity passed on four sentences (13, 61, 123, and 335 input tokens):
exactly equal output lengths and **zero maximum sample difference**. Both
noise scales were zero to make the experiment repeatable.

For “I didn't say you stole it.”, multiplying only a selected word's token
durations by 2.5 produced:

| Selected span | Added frames | Added time |
| --- | ---: | ---: |
| you | 13 | 151 ms |
| stole | 37 | 430 ms |

Every unselected token's rounded duration stayed equal to baseline. Output
sample count increased by exactly added frames × 256. The first vowel-only
attempt added just 23–58 ms and was superseded by this whole-span comparison.

Three listening WAVs use scalar gain only for matched loudness, with sample
peak headroom. The manifest contains model hashes, settings, token alignment,
actual duration changes, and output levels. It verifies the original model's
hash again after synthesis.

Results from this run are in
`/private/tmp/voice-forge-timing.ShqWmb/listening-word-spans` (temporary files).
The modified model is `/private/tmp/voice-forge-timing.ShqWmb/epoch702-timing.onnx`.

**Listener verdict: pacing is good, but the sound is glitchy.** The 2.5 factor is deliberately pronounced
for discrimination, not a recommended natural-emphasis preset. Neither exact
parity nor sample-peak headroom proves naturalness, absence of audible defects,
or successful emotional performance. Test that before app integration, then
validate word mapping across sentences and separately test the Rode model.

### Glitch isolation

The first samples used acoustic noise scale zero for waveform parity, unlike
the model config's 0.667. This is a suspected contributor, not an established
cause. Stretching whole spans (including consonants) by 2.5 is another candidate.

Pass `--texture-check` after the output directory to generate three additional
`*-texture.wav` clips using the model's acoustic noise scale. Duration noise
stays zero. The runner asserts **identical per-token frame counts and output
lengths** for each zero-noise/texture pair, so the accepted timing is retained.
All six clips are loudness-matched. Acoustic noise is unseeded, with one draw
per clip; repeated perceptual comparisons would be needed for robust results.

The initial diagnostic files are in
`/private/tmp/voice-forge-timing.ShqWmb/texture-check`. All four zero-noise parity
cases still pass exactly. The user reports that restoring acoustic noise
removed the glitchiness, but “stole” sounded like “ssttoollee”: whole-word
stretching, not natural emphasis. This is listening evidence for this clip,
not a guarantee across models or sentences. Do not integrate it yet.

### Consonant-preserving vowel comparison

Pass `--vowel-check` to include the texture check and two additional variants
at acoustic noise 0.667. For this exact `stˈoʊl` fixture, only `o`, `ʊ`, and
their following blank tokens receive factors (1.65 and 2). The runner checks
every other token's rounded duration is unchanged, including `s`, `t`, `l`,
their following blanks, the stress marker, and neighboring words. Acoustic
boundaries of blank tokens are not measured, so this is a timing invariant,
not proof that consonant waveforms are unchanged.

The measured additions are 70 ms and 104 ms, versus 430 ms for the rejected
whole-word stretch. Results are in
`/private/tmp/voice-forge-timing.ShqWmb/vowel-check`. Neutral waveform parity
still passes all four cases, and audio length follows the changed alignment
exactly. The user prefers the stronger (104 ms) vowel extension for dramatic
delivery; the gentler version is almost unchanged. This establishes a preferred
timing candidate, not a complete dramatic delivery or emotion control.

### Rise–fall–rise pitch contour

The user's proposed next layer is a lift at “stole”, a drop, then a rise at
“it”. `pitch_alignment.mjs` recovers complete model frame boundaries for the
existing preferred WAV, verifying recorded token durations and total length.
It does not generate a replacement listening take. `pitch_contour.py` applies
a separate pitch-only experiment to that exact WAV with the installed Rubber
Band 4 Live C API, formant preservation enabled. It uses smooth relative
offsets reaching +3, −1.5, then +3 semitones. It is **post-synthesis processing**,
not an additional Piper capability or an absolute F0 trajectory.

```sh
node experiments/piper-timing/pitch_alignment.mjs /absolute/vowel-check/manifest.json /absolute/new-alignment.json
python experiments/piper-timing/pitch_contour.py /absolute/new-alignment.json /absolute/new-pitch-directory
```

The Python environment needs numpy; ffmpeg and Rubber Band 4 must already be
installed. The library path defaults to the local Homebrew path and can be
overridden with `--library`. No app dependencies were changed or bundled.
Any future distribution must review the library's licensing first.

Processing runs at 44.1 kHz, compensates the reported 2142-sample delay, flushes
the tail, and returns exactly 43008 samples at 22.05 kHz (1.95048 seconds).
The target region is mixed in with 30 ms complementary cosine transitions;
samples outside it remain unchanged. No extra pacing, EQ, or gain envelope is
applied. The output includes the preferred reference, a zero-shift processor
control, and the contour. The zero-shift control's whole-clip correlation to
the source is 0.999947; this is not perceptual-quality certification.

A known-sine test checks static pitch shift and that moving peaks fall in the
intended vowel intervals. It caught and corrected a scheduling error where
the second rise landed late. These calibration checks do not measure the
speech's actual F0 contour. The aligned candidate is in
`/private/tmp/voice-forge-timing.ShqWmb/pitch-contour-aligned`; the earlier
`pitch-contour` folder is superseded. The user found this clean but barely
different; it is not an approved expressive-delivery result.

Reference: [Rubber Band Live API](https://www.breakfastquay.com/rubberband/code-doc/classRubberBand_1_1RubberBandLiveShifter.html).

### Speech-based contour placement — 2026-09-16

The user found the first contour clean but barely different. Praat AC/CC
analysis of the actual reference and processed speech showed the second
intended rise (around 1.80s) fell in a very quiet, unvoiced region. At the
earlier final voiced region (1.60–1.665s), the old processing instead lowered
pitch by a paired-frame median of about 1.1 semitones. The synthetic sine test
had verified processor behavior, **not acoustic word boundaries**.

`pitch_contour.py --profile voiced` is explicitly bound to the exact preferred
WAV hash. It moves the second lift onto the final voiced region and uses
stronger +4.5/−2/+4.5 relative offsets. This is a manually placed fixed-clip
experiment, not a solution for general word alignment.

`pitch_report.py` measures both recordings using Praat AC and CC estimators
(40–350 Hz, 5ms steps), retaining paired frames where both estimates agree
within one semitone and short-window RMS exceeds −40dBFS. The new candidate
has median paired shifts of +4.49 semitones in the first lift window and
+4.24 in the final voiced window; the intervening window is −0.33. Estimators
can agree on the wrong octave: use these as relative diagnostics, not certain
absolute F0, word boundaries, or quality ratings.

```sh
python experiments/piper-timing/pitch_contour.py /absolute/alignment.json /absolute/new-directory --profile voiced
python experiments/piper-timing/pitch_report.py /absolute/new-directory/reference.wav /absolute/new-directory/rise-fall-rise.wav /absolute/new-report.json --expect-voiced-rise
```

The report tool additionally requires `praat-parselmouth` (tested with 0.4.7),
installed only in the temporary experiment environment. The optional regression
checks require enough paired voiced frames, a lift in both target regions,
and lower pitch offsets between them; they do not award listening approval.
Current files: `/private/tmp/voice-forge-timing.ShqWmb/pitch-contour-voiced`.
The recording remains 43008 samples, with samples outside the target region
unchanged. **Listener verdict: rejected.** The user hears an oscillating wave,
“I didn't say you StOoOlEiT”, rather than dramatic speech. The app remains
untouched. Passing F0/duration checks established that the processing happened,
not that its prosody was natural. Do not promote this profile into presets or
increase its amplitude in response to the earlier subtle result.

The preferred 104 ms vowel-timing sample and acoustic noise 0.667 remain the
working reference, separately from these rejected pitch experiments. The next
step is to compare phrase-level pitch and timing against a real performance;
the supplied reference analysis is recorded below. No new contour is being
presented as a fix.

Reference: [Parselmouth pitch analysis API](https://parselmouth.readthedocs.io/en/stable/api_reference.html#parselmouth.Sound.to_pitch_ac).

### Three user-performed references — 2026-09-16

User supplied `/Users/tamtor/Documents/Drop/RAW/[RAW] S2 R1.wav` with three
different deliveries. The file is 10.7 seconds, stereo, 48 kHz, 24-bit PCM.
`reference_analysis.py` creates excerpts with original PCM samples and channels
intact, plus pitch CSVs and a provenance/measurement manifest. The source hash
is verified again after processing; no uploads, source edits, normalization,
training, or synthetic speech are involved.

```sh
python experiments/piper-timing/reference_analysis.py /absolute/reference.wav /absolute/new-output-directory
```

Activity thresholding separates takes only at gaps longer than 0.8 seconds,
preserving internal pauses. Excerpts include 150ms margins. Pitch analysis uses
channel-average audio, but extracted WAVs retain the original stereo samples.
AC/CC agreement and voiced-frame checks filter uncertain estimates; no pitch
line is invented through unvoiced gaps. Relative semitones are referenced to
each take's median, not applied as the speaker's absolute pitch to the model.

| Take | Estimated activity interval | Span, including internal pauses | Voiced pitch P5–P95 |
| --- | --- | --- | --- |
| 1 | 1.07–2.84 s | 1.77 s | 79–162 Hz |
| 2 | 4.92–6.44 s | 1.52 s | 82–165 Hz |
| 3 | 7.88–10.02 s | 2.14 s | 85–221 Hz |

These are estimated pitch ranges, not emotional labels or established word
boundaries. In particular, agreeing pitch trackers can still have octave
errors with vocal fry. Take 3 shows the widest measured range and longest
activity span; take 2 is shortest. All three remain separate references;
the user selected **Take 3** as the first transfer target.

Artifacts: `/private/tmp/voice-forge-timing.ShqWmb/reference-s2-r1`.
Each excerpt is verified sample-identical to its corresponding source section.
Do not proportionally stretch a whole reference pitch track onto the synthetic
phrase or trust model token times as acoustic word alignment.

### Take 3 word-register audition

`reference_words.py` uses an existing local ONNX Parakeet model/runtime with
network access disabled. Both recordings independently transcribe as “I didn't
say you stole it.” with the same subword token sequence. Emission timestamps
are approximate landmarks, **not forced phonetic alignment**. No recognizer
or model was added to Voice Forge. The existing runtime in the Protoke venv
was read/executed without editing that project.

Those landmarks and agreed pitch frames put Take 3's strongest elevation
around **you**, then a lower **stole**, and a lift on **it**. This differs from
the earlier guessed emphasis on “stole”. `reference_transfer.py` transfers
only these broad word-level relationships, centered relative to each
recording's median. Strength is 0.75 with a six-semitone shift limit. It keeps
steadier offsets inside words rather than copying every pitch-tracker wiggle,
and uses the same Rubber Band processor to avoid confounding a renderer change.

The first audition is in
`/private/tmp/voice-forge-timing.ShqWmb/take-3-register-audition`.
The original synthetic clip remains 43008 samples; its timing, including the
preferred vowel extension, is retained. This does **not** yet reproduce Take
3's longer “you”, internal pause, full contour, loudness, or breathiness.

Observed relative shifts for “you” and “stole” are consistent with the applied
controls. The final word has a roughly octave-sized pitch-estimation mismatch;
the raw value is retained as `unverified-possible-octave-ambiguity`, and
`allWordsPitchVerified` is false. Do not octave-fold the reported measurement
to manufacture validation. Lowering this deep voice also required an output
analysis floor below 50 Hz to avoid selecting only the unshifted/high frames.
Listening approval is pending. Earlier `take-3-transfer*` folders are failed
measurement iterations, not accepted candidates.

```sh
# Requires an existing onnx-asr environment and a local model directory:
HF_HUB_OFFLINE=1 python experiments/piper-timing/reference_words.py /absolute/local-model /absolute/take-3.wav /absolute/preferred-synthetic.wav /absolute/new-landmarks.json
# Uses the isolated pitch-analysis environment:
python experiments/piper-timing/reference_transfer.py /absolute/new-landmarks.json /absolute/new-audition-directory
```

### Updated R7 reference — 2026-09-16

The user supplied `/Users/tamtor/Documents/Drop/RAW/[RAW] S2 R7.wav` as a cleaner,
normalized recording. Treat it as the updated working reference, not as the
same waveform or performance with a gain adjustment. It is one take in a
3.3-second, mono, 48 kHz, 24-bit file. Activity spans approximately 0.67–2.67s;
the unchanged PCM excerpt includes 150ms margins. Run `reference_analysis.py`
with `--expected-takes 1`; mono files no longer attempt stereo correlation.

The recognizer independently confirms the same sentence. Paired AC/CC pitch
measurements in its approximate word regions show lower “you” (~77 Hz), higher
“stole” (~129 Hz), and higher “it” (~145 Hz). This differs from old Take 3's
high “you” / low “stole”, so direction is now derived from reference data rather
than asserted as a fixed high/low/high pattern.

R7 measurement artifacts: `/private/tmp/voice-forge-timing.ShqWmb/reference-s2-r7`.
The new listening comparison is
`/private/tmp/voice-forge-timing.ShqWmb/r7-register-listening/reference-word-registers.wav`.
The generic output filename replaces the old Take-3-specific filename for
future runs; historical outputs remain intact. The synthetic timing remains
unchanged. Requested shifts are approximately −1.8 / +4.5 / +6 semitones for
“you” / “stole” / “it”, derived from relative word medians with the same limits.

“Stole” measures consistently with the requested shift. “You” and “it” have
possible octave ambiguities in the synthetic pitch estimates, retained as
unverified rather than folded to fit the target. Octave ambiguity must be
classified before interpreting shift direction; it can reverse the apparent
sign of a small downward shift. `allWordsPitchVerified` remains false.
The cleaner reference does not by itself resolve ambiguity in the synthetic
voice. The user **rejected** this audition: it loses coherence and vocal body,
leaving a weak/airy sound. It is not a verified performance match or approved
processor, even where pitch movement was measured successfully.
The earlier `r7-register-audition` folder is an incomplete measurement attempt.

Neither original recording was changed, and no app or bundled model was changed.

### R7 vocal-body diagnosis — 2026-09-16

`voice_integrity.py` reproduces the rejected processing within half a 16-bit
PCM step and compares it with a zero-shift pass and a formant-preservation-off
pass. The neutral pass correlates 0.9998 with the dry source and leaves word
levels essentially unchanged. With the requested shifts, formant preservation
reduces the measured level of “stole” by about 1.2 dB and “it” by 1.65 dB.
Disabling it restores much of that level, but does **not** establish a timbre
fix. HNR increases in the rejected output: periodicity is not vocal coherence
or perceived naturalness. Do not turn that metric into a listening pass.

Report: `/private/tmp/voice-forge-timing.ShqWmb/r7-voice-integrity.json`.
No new listening files were issued by this diagnostic.

`resynthesis_probe.py` then tests Praat TD-PSOLA, changing only the renderer.
It reuses the exact accepted timing WAV, the same R7 shift instructions and
the same outer wet/dry mask. There is no gain matching, EQ, new synthesis or
duration adjustment. Original and neutral-resynthesis controls are retained.
The neutral control really passes through the renderer; it is not a bypass.
Algorithm references: [Praat overlap-add](https://praat.org/manual/overlap-add.html)
and [Parselmouth pitch manipulation](https://parselmouth.readthedocs.io/en/stable/examples/pitch_manipulation.html).

Artifacts: `/private/tmp/voice-forge-timing.ShqWmb/r7-psola-control`.

- All files retain 43008 samples at 22050 Hz; protected outer regions remain
  sample-identical to the source. The dry copy's hash matches the accepted WAV.
- Neutral word levels differ by at most 0.21 dB; paired pitch estimates differ
  by roughly 0.02 / 0.02 / 0.30 semitones on “you” / “stole” / “it”. These are
  signal measurements, not an assertion that the neutral control sounds clean.
- Both neutral and shifted clips retain the sentence and identical token
  emission landmarks in the local recognizer. Recognition is not quality approval.
- The shifted clip fails the pitch-evidence check: “you” retains only 5 of 17
  paired reliable frames; “it” measures about −6 semitones against a +6 command.
  The manipulation pitch tier and analysis disagree by an octave in the final
  word. No octave folding is used to conceal this disagreement.
- Shifted word levels fall by about 1.6 / 2.4 / 1.8 dB. This does not establish
  the same perceptual defect, but it is not evidence that the weak voice is fixed.

The shifted TD-PSOLA output is withheld as a replacement candidate. The user
compared `r7-psola-control/dry.wav` with `r7-psola-control/neutral.wav` and reports
they are **identical by ear**. This approves that specific zero-shift control's
transparency, not the shifted version or a general expressive-voice capability.
App integration remains blocked on acoustic verification and listening approval.
The preferred vowel-timing result remains intact.

```sh
python experiments/piper-timing/voice_integrity.py /absolute/r7-manifest.json /absolute/new-report.json
python experiments/piper-timing/resynthesis_probe.py /absolute/r7-manifest.json /absolute/new-output-directory
```

### Single-region pitch isolation

After the neutral listening pass, `word_isolation.py` isolates the existing
TD-PSOLA output around “stole”, the word with consistent shift measurements.
It does not re-render, increase the shift or redesign the contour. Only the
approximate 1.2–1.6s ASR region is mixed into the original source, with 15ms
crossfades inside its boundaries. Everything outside is sample-identical to
the preferred source after WAV encoding, so “you” and “it” retain their original
samples. This is a fixed-clip diagnostic, not precise word alignment.

Artifacts: `/private/tmp/voice-forge-timing.ShqWmb/r7-stole-isolation`.
`stole-pitch-shifted.wav` measures about +4.42 semitones across 37 paired reliable
frames, consistent with the original command around +4.45. Its measured word
level remains about 2.38dB lower; no automatic gain compensation conceals that.
A corresponding `stole-neutral.wav` isolates possible crossfade artifacts.
Both retain the source duration. The user **rejected** the shifted region:
“stoole” sounds stretched, with light crackling described as high- and low-pitched
static embedded in the word. A measured shift and intelligible transcription
did not establish preserved timbre. The neutral-control listening pass remains
valid for that control only; it does not rescue the shifted version.

```sh
python experiments/piper-timing/word_isolation.py /absolute/psola-manifest.json /absolute/new-output-directory --word stole
```

`isolation_integrity.py` verifies that the interior 1.215–1.585s (370ms) is
sample-identical to the earlier full-phrase TD-PSOLA output. The new crossfades
only mix the first/last 15ms of the selected region. All three inspected files
retain 43008 samples, peak at about −10.03dBFS and have no samples at the PCM
rails. This excludes added total duration and sample clipping, and excludes
new isolation edits inside that 370ms span. It does not rule out audible edge
artifacts or establish the precise resynthesis failure behind the crackling.

The source already contains the previously preferred +104.49ms vowel extension.
That duration fact does not invalidate the new report of perceived stretching;
duration preservation alone is not a sufficient acceptance test. Do not stack
more EQ, gain restoration or stronger curves onto this rejected output. Keep
the clean timing experiment separate, and require a new causal test of pitched
resynthesis before presenting another expressive candidate. No new audio or app
change is issued in response to this rejection.

Report: `/private/tmp/voice-forge-timing.ShqWmb/r7-stole-isolation/integrity.json`.

```sh
python experiments/piper-timing/isolation_integrity.py /absolute/isolation-manifest.json /absolute/new-report.json
```

### Original-duration fixed-pitch test

Following approval of the bounded diagnostic plan, `fixed_pitch_probe.py` uses
the existing `vowel-check/0-reference-texture.wav`: original duration, normal
acoustic noise 0.667, no added vowel time. SHA-256:
`ba08fae0b57a776dbd3036eb58d61057a2114a43f4f76adfef8ac68288b1cfdf`.
It is 40704 samples at 22050Hz (1.846s). Each comparison starts from this exact
recording. It is a different saved acoustic-noise draw from the stretched take;
do not attribute differences between the two sources solely to vowel duration.

Local recognition re-establishes approximate “stole” landmarks at 1.12–1.52s.
The visually inspected waveform/pulse audit compares 50Hz and 40Hz pitch floors.
At the onset, 50Hz-floor analysis detects a short ~95–110Hz region that the
40Hz-floor analysis leaves unvoiced. Pulse placement differs there, including
a ~20.3ms gap in the 50Hz-floor pulse track. The middle 1.40–1.48s is more stable:
both pulse tracks and AC/CC pitch estimates broadly agree around 63–58Hz.
These observations do not prove which onset interpretation is correct or that
it caused the earlier crackle. No hand-corrected pulse track is claimed.

The test renders constant **offsets** of 0, +1 and +4.4501 semitones (preserving
the underlying source contour), not a fixed absolute pitch or a dramatic curve.
Only the approximate word region is mixed back, with the same 15ms edge fades;
samples outside it remain identical after WAV encoding. No EQ, added time or
gain restoration is applied. Measurements refer to the stable core; listening
still includes the disputed onset and may reveal defects those measurements miss.

The 50Hz-floor variants measure −0.053 / +0.945 / +4.382 semitones in the core;
the 40Hz-floor variants measure −0.016 / +0.971 / +4.382. All retain 40704 samples
and the original −8.43dBFS sample peak. Agreement does not establish quality.
Keep the original 50Hz setting for the initial audition instead of selecting
another setting simply because one metric is slightly better. WORLD has not
been installed or benchmarked; listening to the controlled test comes first.

Artifacts: `/private/tmp/voice-forge-timing.ShqWmb/original-duration-fixed-pitch-verified`.
`comparison.wav` contains dry → neutral → +1 → +4.45, separated by 650ms silence.
Its component PCM is verified unchanged by concatenation. `comparison.json`
provides exact segment offsets. The new original-duration neutral and shifted
clips all await listening; earlier acceptance of a different neutral fixture
does not automatically approve these. Rode and additional sentences remain untested.

Calibration caught a no-op in the first version of this new test: Praat's
`Multiply frequencies` command with a 0–0 interval changed no tier points.
The corrected code uses the explicit tier domain and checks every multiplied
point. The earlier `original-duration-fixed-pitch` folder is invalid for pitch
comparison, not an audition. This bug was confined to the new constant-shift
test; earlier scripts explicitly constructed shifted tier points. Four unit
tests now check actual tier/audio shifts on a known tone, duration, distinct
outputs, invalid controls, and exact comparison PCM. A stricter 0.35-semitone
evidence tolerance prevents an unshifted signal passing the +1 test under the
older exploratory 1.5-semitone tolerance. No perceptual-quality gate is inferred.

```sh
python -m unittest discover -s experiments/piper-timing -p 'test_fixed_pitch_probe.py' -v
MPLCONFIGDIR=/absolute/temporary-matplotlib-cache python experiments/piper-timing/fixed_pitch_probe.py /absolute/original-duration.wav /absolute/new-output-directory
```

Matplotlib was added only to the isolated experiment environment for the
waveform/pulse audit; no app dependency or bundled voice was changed.

### Listener-localized consonant/onset test

The user reports **slight crackling at the letter “t” in “stole” in versions
3 and 4** of the original-duration sequence (+1 and +4.45 semitones). This is
more localized feedback than the earlier stretched-voice rejection. Do not
infer that every other aspect or voice is approved, but do use this location
to test the consonant-to-vowel transition before changing renderers.

Sample comparison finds only tiny differences (at most two 16-bit PCM steps)
in 1.12–1.32s for dry versus processed audio. Larger differences begin around
the transition into voicing, which overlaps the previously observed tracking
disagreement. These are waveform differences, not a measurement of crackle or
an exact acoustic boundary for “t”.

`onset_guard_probe.py` performs a single controlled ablation: keep the exact dry
recording through 1.390s, crossfade over 20ms, and reuse the previous shifted
output unchanged from 1.410s onward. The guard deliberately includes some vowel
onset as well as the consonant; it is a manual, hash-bound fixture boundary,
not a general phoneme detector or a corrected pitch track. Shift magnitude,
remaining vowel waveform, duration and levels are not retuned. A new neutral
guard control tests whether this crossfade itself is audible.

Artifacts: `/private/tmp/voice-forge-timing.ShqWmb/original-duration-onset-guard`.
The listening order remains dry → neutral → +1 → +4.45. All clips have 40704
samples; the protected prefix is verified sample-identical to dry, and all
samples from 1.410s onward match the corresponding previous variant exactly.
Later-vowel estimates remain approximately +0.97 / +4.41 semitones, so this is
not a weaker pitch command disguised as a fix. It does shorten the portion of
the vowel receiving the shift. After being asked to check both “t” and any
artifact moved into “o”, the user reports **“All clean now”** for this sequence.
That is a cleanliness pass for this dry/neutral/+1/+4.45 fixed-clip comparison,
not an approval of emotional acting, reference matching or all speech. No app
change or WORLD benchmark has been made. Seven diagnostic unit tests pass, including guard boundaries,
exact source/processed-region preservation and constant-shift calibration.

This supports preserving the disputed consonant/vowel onset while shifting the
later stable vowel. It does not prove the precise crackling mechanism or that
1.390s is a general boundary. Preserve these exact passing outputs as a listening
reference. The next development gate is automatic detection of safe voiced
regions, with uncertain transitions left dry, followed by additional sentences
and independent Suno/Rode validation. Retain unchanged-prefix and shifted-core
checks so an all-dry/no-effect output cannot pass merely by sounding clean.
Do not integrate the hard-coded timestamp into the app or resume expressive
contours before this control generalizes.

```sh
python -m unittest discover -s experiments/piper-timing -p 'test_*probe.py' -v
python experiments/piper-timing/onset_guard_probe.py /absolute/fixed-pitch-manifest.json /absolute/new-output-directory
```

### Per-sound weighting, generalised off the fixture — 2026-09-16

The whole-span stretch was rejected as "ssttoollee" and the vowel-only variant
at the same magnitude was preferred. Both were hand-picked spans on one clip.
`per_sound_audition.mjs` turns that distinction into a rule and runs it on four
sentences: a phoneme class map decides how much of a direction each sound
receives, so a request to hold a word reaches its vowels in full, its liquids
about half, its unvoiced friction barely, and its stops not at all.

The map lives in the app core, not in this directory —
`cross-platform/src/core/phonology.ts` for the classes and
`cross-platform/src/core/timingPlan.ts` for turning a word-level direction into
one factor per token. Only the two ends of the susceptibility scale are settled
by listening; the values between them are a starting ordering and are the first
thing to retune. The app's own encoder now reports its token layout
(`VoiceEngine.tokenLayout`), so the factor vector is built from the ids actually
sent rather than from a reconstruction that could drift. Token ids are unchanged:
the parity suite still reports 1.637 s against Swift's 1.637 s.

An accent is the stressed nucleus held beyond the rest of its own word, plus
1.5 dB of raised-cosine lift across the word. espeak writes the stress mark
immediately before its syllable, so the nucleus is addressable without a
syllabifier; one-syllable words espeak leaves unmarked fall back to their first
vowel run. **No pitch is shifted.** The duration output also gives exact
token-to-sample boundaries, so the lift is placed on the model's own alignment
rather than on recogniser landmarks — the weakness that ran through the earlier
pitch attempts.

Checks that ran, per take:

- A vector of ones reproduces the stock model with **max error 0.00e+0** across
  all four sentences — bit-identical, not merely within tolerance.
- `vf_base_frames` is unchanged by any direction, so the underlying duration
  prediction never moved.
- Every token outside the directed word keeps its exact predicted frame count.
- Inside the directed word, every token whose class susceptibility is zero keeps
  its exact frame count. This is the "ssttoollee" rejection asserted rather than
  intended.
- Output sample count is a whole number of frames, and no clip reaches the
  sample ceiling.

Measured additions, uniform versus per sound: 290/139 ms on "stole", 406/267 ms
on "slowly", 151/104 ms on "really", 441/255 ms on "furious". The per-sound
figure for "stole" lands near the +104 ms vowel extension that was preferred
earlier, which is a consistency observation and not an approval.

Artifacts are written to `experiments/piper-timing/auditions/` (gitignored).
The page carries its audio inline so it plays away from that directory.

```sh
node experiments/piper-timing/per_sound_audition.mjs /absolute/epoch702-timing.onnx /absolute/out-dir
```

**Listening verdict: pending.** Passing every check above establishes that the
intended tokens moved and no others did. It does not establish that a held vowel
reads as delivery, that the weights between the two settled ends are right, or
that an accent reads as emphasis rather than as length. The app is unchanged and
the experimental graph still must not be installed in it.

#### Accent level and placement

The user reported the 1.5 dB lift too subtle. Two things changed, and only one
of them is the number.

The lift was a single raised cosine across the whole word, so it peaked at the
word's midpoint — which lands on a consonant as often as on the vowel being
accented. It now reaches full value across the nucleus and ramps either side of
it, so the loudest moment is where the accent is. Ramps are never shorter than
one frame, borrowed from the nucleus when a word opens straight onto its vowel,
so the gain cannot step. The suite asserts full level at the nucleus midpoint,
less than full level on the stop in front of it, and no sample-to-sample jump.

The audition now offers +3, +4.5 and +6 dB. Those three takes share one
inference: their duration factors are identical, and acoustic noise is unseeded,
so rendering them separately would have made a listener judging a 1.5 dB step
hear a different noise draw at the same time. With the draw shared, sample peaks
rise monotonically with the lift — about 1.4 dB per step. "The boat goes slowly"
holds at −9.25 dBFS across all three because its sample peak falls outside the
accented word, which is the envelope staying where it was put.

Headroom at +6 dB is −4.11 dBFS at worst. No limiting or compression is applied
and none should be added to make a larger lift fit.

**Listening verdict: pending.** Level selection is the open question.

The user selected **+6 dB**. It is now `TimingPlan.fullAccentDB` in both cores
rather than a number at a call site, next to the headroom figure it has to keep.
The dial that reaches it also moves the nucleus hold, because an accent that is
only long reads as a drawl and one that is only loud reads as a mistake.

The phoneme class map and the plan builder are now ported to Swift and held to
the same 53 assertions as the TypeScript suite, wording included. Both engines
report their token layout from the same loop that builds their ids. Ids are
unchanged on both sides: parity still reads 1.637 s against 1.637 s.
