#!/usr/bin/env python3
"""Diagnose rejected R7 processing without issuing another listening candidate.

Replays the exact failed processing and compares neutral and formant-off paths.
Metrics describe signal changes only; they do not certify perceptual quality.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import parselmouth
from pitch_contour import PitchOnly, resample, smooth_curve


def summarize(samples, rate, regions):
    s = parselmouth.Sound(samples, sampling_frequency=rate)
    h = s.to_harmonicity_cc(time_step=.005, minimum_pitch=40,
                          silence_threshold=.01, periods_per_window=2)
    ht, hv = h.xs(), h.values[0]
    out = []
    for word, lo, hi in regions:
        segment = samples[round(lo*rate):round(hi*rate)]
        sel = (ht >= lo) & (ht <= hi) & (hv > -100)
        out.append({'word': word, 'rmsDBFS': float(20*np.log10(np.sqrt(np.mean(segment**2)))),
                    'medianHNRDB': float(np.median(hv[sel])) if sel.any() else None})
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('manifest', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--library', type=Path, default=Path('/opt/homebrew/lib/librubberband.dylib'))
    a = p.parse_args()
    m = json.loads(a.manifest.read_text())
    path = Path(m['synthetic']['path'])
    assert hashlib.sha256(path.read_bytes()).hexdigest() == m['synthetic']['sha256']
    s = parselmouth.Sound(str(path))
    rate = int(s.sampling_frequency)
    x = s.values[0].astype(np.float32)
    up = resample(x, rate, 44100)
    points = m['semitoneOffsetPoints']
    times = np.arange(len(x))/rate
    start, end = points[1][0], points[-2][0]
    wet = np.minimum(np.clip((times-start)/.03, 0, 1), np.clip((end-times)/.03, 0, 1))
    wet = .5-.5*np.cos(np.pi*wet)
    clips = {'dry': x}
    for name, envelope, preserve in [
        ('neutral', lambda _: 0, True),
        ('shift-preserved-formants', smooth_curve(points), True),
        ('shift-unpreserved-formants', smooth_curve(points), False),
    ]:
        raw, _ = PitchOnly(a.library, formant_preserved=preserve).run(up, 44100, envelope)
        shifted = resample(raw, 44100, rate)
        assert len(shifted) == len(x) and np.isfinite(shifted).all()
        clips[name] = x+wet*(shifted-x)
        assert np.array_equal(clips[name][wet == 0], x[wet == 0])
    rejected = parselmouth.Sound(str(a.manifest.parent/'reference-word-registers.wav')).values[0]
    reproduction_error = float(np.max(np.abs(clips['shift-preserved-formants']-rejected)))
    assert reproduction_error <= 1/32768, 'Did not reproduce the rejected file'
    regions = [(row['word'], *row['sourceVoicedWindow']) for row in m['wordTargets']]
    report = {'sourceSHA256': m['synthetic']['sha256'], 'reproductionMaxError': reproduction_error,
              'listenerVerdict': 'Rejected: loss of voice coherence; weak/airy output.',
              'paths': {name: {'regions': summarize(data, rate, regions),
                               'correlationWithDry': float(np.corrcoef(x, data)[0, 1]),
                               'rmsErrorAgainstDry': float(np.sqrt(np.mean((data-x)**2))),
                               'sampleCount': len(data)} for name, data in clips.items()},
              'limitations': ['No new candidate WAVs emitted.',
                              'Changed pitch necessarily changes waveform correlation.',
                              'HNR measures periodicity, not voice identity or naturalness.',
                              'No perceptual verdict or fix established for formant-off path.']}
    assert hashlib.sha256(path.read_bytes()).hexdigest() == m['synthetic']['sha256']
    with a.output.open('x') as out:
        json.dump(report, out, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
