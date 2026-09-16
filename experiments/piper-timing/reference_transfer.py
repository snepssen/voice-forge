#!/usr/bin/env python3
"""First reference-derived word-register comparison for YOU / STOLE / IT.

R7 LISTENING VERDICT: rejected for loss of voice coherence / weak airy sound.
Retained for diagnosis, not a working expressive-voice feature.
Uses actual recordings and matched ASR landmarks. Transfers broad relative
pitch relationships, not tracker wiggles, timing, emotion, or a full performance.
Original files and app remain unchanged. Requires numpy, praat-parselmouth,
ffmpeg, and installed Rubber Band Live (same processor as earlier tests).
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import parselmouth

from pitch_contour import PitchOnly, resample, smooth_curve, write_wav


def measurements(path, pitch_floor=50):
    raw = parselmouth.Sound(str(path))
    sound = parselmouth.Sound(np.mean(raw.values, axis=0), sampling_frequency=raw.sampling_frequency)
    kwargs = dict(time_step=.005, pitch_floor=pitch_floor, pitch_ceiling=400)
    ac, cc = sound.to_pitch_ac(**kwargs), sound.to_pitch_cc(**kwargs)
    t = ac.xs()
    f = ac.selected_array['frequency']
    other = np.array([cc.get_value_at_time(float(time)) for time in t])
    good = (f > 0) & (other > 0) & np.isfinite(other)
    difference = np.full_like(f, np.inf)
    difference[good] = np.abs(12*np.log2(f[good]/other[good]))
    energy = np.array([np.sqrt(np.mean(sound.values[0,
        max(0, int((time-.01)*sound.sampling_frequency)):
        min(sound.n_samples, int((time+.01)*sound.sampling_frequency))]**2)) for time in t])
    good &= (difference < 1) & (energy > .01)
    assert good.sum() > 20
    return sound, t, f, good, float(np.median(f[good]))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('landmarks', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--library', type=Path, default=Path('/opt/homebrew/lib/librubberband.dylib'))
    a = p.parse_args()
    marks = json.loads(a.landmarks.read_text())['clips']
    assert len(marks) == 2
    expected = [' I', ' didn', "'", 't', ' say', ' you', ' st', 'o', 'le', ' it', '.']
    for clip in marks:
        assert clip['tokens'] == expected, 'Unexpected word sequence; do not guess correspondence'
        assert hashlib.sha256(Path(clip['path']).read_bytes()).hexdigest() == clip['sha256']
    reference, rt, rf, rg, rmedian = measurements(marks[0]['path'])
    source, st, sf, sg, smedian = measurements(marks[1]['path'])
    assert source.sampling_frequency == 22050 and source.n_channels == 1
    rows, points = [], []
    for word, i, j in [('you', 5, 6), ('stole', 6, 9), ('it', 9, 10)]:
        rlo, rhi = marks[0]['timestamps'][i], marks[0]['timestamps'][j]
        slo, shi = marks[1]['timestamps'][i], marks[1]['timestamps'][j]
        rsel, ssel = rg & (rt >= rlo) & (rt < rhi), sg & (st >= slo) & (st < shi)
        assert rsel.sum() >= 5 and ssel.sum() >= 5, f'Not enough agreed voicing for {word}'
        rword, sword = float(np.median(rf[rsel])), float(np.median(sf[ssel]))
        reference_relative = 12*np.log2(rword/rmedian)
        source_relative = 12*np.log2(sword/smedian)
        requested = float(.75 * (reference_relative-source_relative))
        applied = float(np.clip(requested, -6, 6))
        begin, end = float(st[ssel][0]), float(st[ssel][-1])
        inset = min(.035, (end-begin)/4)
        points.extend([(begin+inset, applied), (end-inset, applied)])
        rows.append({'word': word, 'referenceWordMedianHz': rword, 'sourceWordMedianHz': sword,
                     'referenceRelativeSemitones': float(reference_relative),
                     'sourceRelativeSemitones': float(source_relative),
                     'requestedShift': requested, 'appliedShift': applied,
                     'referenceASRWindow': [rlo, rhi], 'sourceASRWindow': [slo, shi],
                     'sourceVoicedWindow': [begin, end], 'referenceFrames': int(rsel.sum()),
                     'sourceFrames': int(ssel.sum())})
    start = rows[0]['sourceVoicedWindow'][0] - .07
    end = min(source.duration, rows[-1]['sourceVoicedWindow'][1] + .09)
    points = [(0, 0), (start, 0)] + points + [(end, 0), (source.duration, 0)]
    assert all(x[0] < y[0] for x, y in zip(points, points[1:]))
    # Derive direction from each recording, never hard-code Take 3's high/low/high.
    # The replacement R7 reference has a different word-register pattern.
    assert all(np.isfinite(row['appliedShift']) and abs(row['appliedShift']) <= 6 for row in rows)
    x = source.values[0].astype(np.float32)
    processor = PitchOnly(a.library)
    up = resample(x, 22050, 44100)
    altered, latency = processor.run(up, 44100, smooth_curve(points))
    shifted = resample(altered, 44100, 22050)
    assert len(shifted) == len(x)
    times = np.arange(len(x))/22050
    wet = np.minimum(np.clip((times-start)/.03, 0, 1), np.clip((end-times)/.03, 0, 1))
    wet = .5 - .5*np.cos(np.pi*wet)
    y = x + wet*(shifted-x)
    assert np.array_equal(y[wet == 0], x[wet == 0])
    a.output.mkdir(parents=True, exist_ok=False)
    write_wav(a.output/'synthetic-reference.wav', x, 22050)
    write_wav(a.output/'reference-word-registers.wav', y, 22050)
    # The downward shift can take this already deep voice below 50 Hz. A
    # wider analysis range avoids silently discarding the lowered vowel.
    _, yt, output_f, output_good, _ = measurements(a.output/'reference-word-registers.wav', pitch_floor=35)
    # Different pitch floors have different analysis window/grid origins.
    # Nearest 5ms frames keep the actual comparison at source time points.
    near = np.abs(yt[:, None]-st[None, :]).argmin(axis=0)
    yf, yg = output_f[near], output_good[near] & (np.abs(yt[near]-st) <= .003)
    for row in rows:
        lo, hi = row['sourceASRWindow']
        sel = sg & yg & (st >= lo) & (st < hi)
        assert sel.sum() >= 5, f'Insufficient paired pitch observations for {row["word"]}'
        row['measuredPairedShift'] = float(np.median(12*np.log2(yf[sel]/sf[sel])))
        row['pairedFrames'] = int(sel.sum())
        # Classify octave ambiguity before testing direction: an octave jump
        # in tracking can reverse the apparent sign of a small downward shift.
        error = row['measuredPairedShift']-row['appliedShift']
        if abs(error) < 1.5:
            if abs(row['appliedShift']) >= 1.5:
                assert np.sign(row['measuredPairedShift']) == np.sign(row['appliedShift'])
            row['pitchVerification'] = 'relative-shift-consistent'
        elif abs(abs(error)-12) < 1.5:
            # Do not fold the number down an octave to manufacture a pass.
            # Preserve raw estimates and explicitly withhold verification.
            row['pitchVerification'] = 'unverified-possible-octave-ambiguity'
        else:
            raise AssertionError(f'Unexplained pitch mismatch for {row["word"]}: {error}')
    report = {'reference': marks[0], 'synthetic': marks[1], 'wordTargets': rows,
              'referenceGlobalMedianHz': rmedian, 'sourceGlobalMedianHz': smedian,
              'transferStrength': .75, 'maxShiftSemitones': 6, 'semitoneOffsetPoints': points,
              'allWordsPitchVerified': all(r['pitchVerification'] == 'relative-shift-consistent' for r in rows),
              'sampleCount': len(x), 'seconds': len(x)/22050,
              'peakDBFS': float(20*np.log10(np.max(np.abs(y)))),
              'latency': latency, 'sourceUnchanged': True,
              'limitations': ['Approximate ASR landmarks, not forced word boundaries.',
                              'Word medians transfer broad register relationships, not exact contours.',
                              'Pitch estimates may have octave ambiguity.',
                              'Synthetic timing retained; reference pause and duration not copied.',
                              'No loudness or breathiness transfer; no emotional claim.',
                              'Listening approval pending; no app integration.']}
    for clip in marks:
        assert hashlib.sha256(Path(clip['path']).read_bytes()).hexdigest() == clip['sha256']
    with (a.output/'manifest.json').open('x') as out:
        json.dump(report, out, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
